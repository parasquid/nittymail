# frozen_string_literal: true

# Copyright 2025 parasquid

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

module NittyMail
  module SyncUtils
    module_function

    def filter_mailboxes_by_only_list(selectable_mailboxes, only_mailboxes)
      return selectable_mailboxes if only_mailboxes.nil? || only_mailboxes.empty?

      include_regexes = only_mailboxes.map do |pat|
        escaped = Regexp.escape(pat.to_s)
        escaped = escaped.gsub(/\\\*/m, ".*")
        escaped = escaped.gsub(/\\\?/m, ".")
        Regexp.new("^#{escaped}$", Regexp::IGNORECASE)
      end

      before = selectable_mailboxes.size
      kept = selectable_mailboxes.select { |mb| include_regexes.any? { |rx| rx.match?(mb.name) } }
      dropped = selectable_mailboxes - kept

      if kept.any?
        puts "including #{kept.size} mailbox(es) via --only: #{kept.map(&:name).join(", ")} (was #{before})"
      else
        puts "--only matched 0 mailboxes; nothing to process"
      end
      puts "skipping #{dropped.size} mailbox(es) due to --only" if dropped.any?

      kept
    end

    def filter_mailboxes_by_ignore_list(selectable_mailboxes, ignore_mailboxes)
      return selectable_mailboxes if ignore_mailboxes.nil? || ignore_mailboxes.empty?

      regexes = ignore_mailboxes.map do |pat|
        escaped = Regexp.escape(pat.to_s)
        escaped = escaped.gsub(/\\\*/m, ".*")
        escaped = escaped.gsub(/\\\?/m, ".")
        Regexp.new("^#{escaped}$", Regexp::IGNORECASE)
      end

      before = selectable_mailboxes.size
      ignored, kept = selectable_mailboxes.partition { |mb| regexes.any? { |rx| rx.match?(mb.name) } }

      if ignored.any?
        ignored_names = ignored.map(&:name)
        puts "ignoring #{ignored_names.size} mailbox(es): #{ignored_names.join(", ")}"
      end
      puts "will consider #{kept.size} selectable mailbox(es) after ignore filter (was #{before})"

      kept
    end

    def handle_prune_missing(db, prune_missing, status, mbox_name, uidvalidity, db_only, reporter)
      if prune_missing && status != :aborted
        if db_only.any?
          count = db.transaction { NittyMail::DB.prune_missing!(db, mbox_name, uidvalidity, db_only) }
          reporter.event(:pruned_missing, {mailbox: mbox_name, uidvalidity: uidvalidity, pruned: count})
          count
        else
          reporter.event(:prune_none, {mailbox: mbox_name, uidvalidity: uidvalidity})
          0
        end
      elsif prune_missing && status == :aborted
        reporter.event(:prune_skipped_due_to_abort, {mailbox: mbox_name, uidvalidity: uidvalidity})
        0
      elsif !prune_missing && db_only.any?
        reporter.event(:prune_candidates_present, {mailbox: mbox_name, uidvalidity: uidvalidity, candidates: db_only.size})
        0
      end
    end

    def handle_purge_old_validity(db, email_ds, settings, mbox_name, uidvalidity, reporter, stdin: $stdin)
      other_validities = email_ds.where(mailbox: mbox_name).exclude(uidvalidity: uidvalidity).distinct.select_map(:uidvalidity)
      return 0 if other_validities.empty?

      do_purge = false
      if settings.purge_old_validity
        do_purge = true
      elsif stdin.tty? && !settings.auto_confirm
        print "Detected old UIDVALIDITY data for '#{mbox_name}' (#{other_validities.join(", ")}). Purge now? [y/N]: "
        ans = stdin.gets&.strip&.downcase
        do_purge = %w[y yes].include?(ans)
      end

      if do_purge
        count = email_ds.where(mailbox: mbox_name).exclude(uidvalidity: uidvalidity).count
        db.transaction do
          email_ds.where(mailbox: mbox_name).exclude(uidvalidity: uidvalidity).delete
        end
        reporter.event(:purge_old_validity, {mailbox: mbox_name, uidvalidity: uidvalidity, purged: count})
        count
      else
        reporter.event(:purge_skipped, {mailbox: mbox_name, uidvalidity: uidvalidity})
        0
      end
    end

    # New: preflight worker helper with injectable IMAP
    def preflight_worker_with_imap(imap, email_ds, mbox_queue, preflight_results, preflight_mutex, reporter, db_mutex)
      while (mailbox = begin
        mbox_queue.pop(true)
      rescue
        nil
      end)
        mbox_name = mailbox.name
        pfcalc = NittyMail::Preflight.compute(imap, email_ds, mbox_name, db_mutex)
        uidvalidity = pfcalc[:uidvalidity]
        uids = pfcalc[:to_fetch]
        db_only = pfcalc[:db_only]
        server_size = pfcalc[:server_size]
        db_size = pfcalc[:db_size]

        preflight_mutex.synchronize do
          preflight_results << {name: mbox_name, uidvalidity: uidvalidity, uids: uids, db_only: db_only}
          reporter.event(:preflight_mailbox, {
            mailbox: mbox_name,
            uidvalidity: uidvalidity,
            to_fetch: uids.size,
            to_prune: db_only.size,
            server_size: server_size,
            db_size: db_size,
            uids_preview: NittyMail::Logging.format_uids_preview(uids)
          })
        end
      end
    end

    # New: mailbox processing helper
    def process_mailbox(email_ds:, settings:, preflight_result:, threads_count:, fetch_batch_size:, reporter:, db:)
      mbox_name = preflight_result[:name]
      uidvalidity = preflight_result[:uidvalidity]
      uids = preflight_result[:uids]

      if uids.nil? || uids.empty?
        reporter.event(:mailbox_skipped, {mailbox: mbox_name, reason: :nothing_to_fetch})
        return {status: :skipped, mailbox: mbox_name, uidvalidity: uidvalidity, total: 0, processed: 0, errors: 0, pruned: 0, purged: 0}
      end

      thread_word = (threads_count.to_i == 1) ? "thread" : "threads"
      reporter.event(:mailbox_started, {mailbox: mbox_name, uidvalidity: uidvalidity, total: uids.size, threads: threads_count, thread_word: thread_word})

      result = NittyMail::MailboxRunner.run(
        settings: settings,
        email_ds: email_ds,
        mbox_name: mbox_name,
        uidvalidity: uidvalidity,
        uids: uids,
        threads_count: threads_count,
        fetch_batch_size: fetch_batch_size,
        progress: reporter
      )

      db_only = preflight_result[:db_only] || []
      status = result.is_a?(Hash) ? result[:status] : result
      processed_msgs = result.is_a?(Hash) ? (result[:processed] || uids.size) : uids.size
      error_count = result.is_a?(Hash) ? (result[:errors] || 0) : 0

      pruned_count = handle_prune_missing(db, settings.prune_missing, status, mbox_name, uidvalidity, db_only, reporter) || 0
      purged_count = handle_purge_old_validity(db, email_ds, settings, mbox_name, uidvalidity, reporter) || 0

      reporter.event(:mailbox_summary, {
        mailbox: mbox_name,
        uidvalidity: uidvalidity,
        total: uids.size,
        prune_candidates: db_only.size,
        pruned: pruned_count,
        purged: purged_count,
        processed: processed_msgs,
        errors: error_count,
        result: status
      })
      reporter.event(:mailbox_finished, {mailbox: mbox_name, uidvalidity: uidvalidity, processed: processed_msgs, result: status})

      {status: status, mailbox: mbox_name, uidvalidity: uidvalidity, total: uids.size, processed: processed_msgs, errors: error_count, pruned: pruned_count, purged: purged_count}
    end
  end
end
