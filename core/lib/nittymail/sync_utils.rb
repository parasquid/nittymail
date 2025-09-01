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
  end
end
