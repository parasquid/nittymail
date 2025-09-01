#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright 2023 parasquid

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

require "bundler/setup"
require "time"
require "debug"
require "mail"
require "sequel"
require "json"
require "net/imap"
require "openssl"
require "ruby-progressbar"
require_relative "lib/nittymail/util"
require_relative "lib/nittymail/logging"
require_relative "lib/nittymail/gmail_patch"
require_relative "lib/nittymail/db"
require_relative "lib/nittymail/preflight"
require_relative "lib/nittymail/imap_client"
require_relative "lib/nittymail/mailbox_runner"
require_relative "lib/nittymail/settings"
require_relative "lib/nittymail/reporter"

module SyncSettings
  class Settings < NittyMail::BaseSettings
    attr_accessor :imap_address, :imap_password, :mailbox_threads, :purge_old_validity,
      :auto_confirm, :fetch_batch_size, :ignore_mailboxes, :only_mailboxes,
      :strict_errors, :prune_missing, :sqlite_wal, :reporter, :on_progress

    REQUIRED = [:imap_address, :imap_password, :database_path].freeze

    DEFAULTS = BASE_DEFAULTS.merge({
      mailbox_threads: 1,
      purge_old_validity: false,
      auto_confirm: false,
      fetch_batch_size: 100,
      ignore_mailboxes: [],
      only_mailboxes: [],
      strict_errors: false,
      prune_missing: false,
      sqlite_wal: true,
      reporter: nil,
      on_progress: nil
    }).freeze
  end
end

# Ensure immediate flushing so output appears promptly in Docker
$stdout.sync = true

# patch only this instance of Net::IMAP::ResponseParser
def patch(gmail_imap)
  NittyMail::GmailPatch.apply(gmail_imap)
end

# Build a DB record from a Mail object and IMAP attrs
def build_record(imap_address:, mbox_name:, uid:, uidvalidity:, mail:, attrs:, flags_json:, raw:, strict_errors: false)
  date = begin
    mail&.date
  rescue Mail::Field::NilParseError, ArgumentError
    raise if strict_errors
    warn "Error parsing date for #{mail&.subject}"
    nil
  end

  subject_str = NittyMail::Util.extract_subject(mail, raw, strict_errors: strict_errors)

  {
    address: imap_address,
    mailbox: NittyMail::Util.safe_utf8(mbox_name),
    uid:,
    uidvalidity:,

    message_id: NittyMail::Util.safe_utf8(mail&.message_id),
    date:,
    internaldate: attrs&.fetch("INTERNALDATE", nil),
    from: NittyMail::Util.safe_json(mail&.from, on_error: "encoding error for 'from' while building record; subject: #{subject_str}", strict_errors: strict_errors),
    subject: subject_str,
    has_attachments: mail ? mail.has_attachments? : false,

    x_gm_labels: NittyMail::Util.safe_utf8(attrs["X-GM-LABELS"].to_s),
    x_gm_msgid: NittyMail::Util.safe_utf8(attrs["X-GM-MSGID"].to_s),
    x_gm_thrid: NittyMail::Util.safe_utf8(attrs["X-GM-THRID"].to_s),
    flags: NittyMail::Util.safe_utf8(flags_json),

    encoded: NittyMail::Util.safe_utf8(raw)
  }
end

# Log a concise processing line (handles odd headers safely)
def log_processing(mbox_name:, uid:, mail:, flags_json:, raw:, progress: nil, strict_errors: false)
  subj = NittyMail::Util.extract_subject(mail, raw, strict_errors: strict_errors)
  from = NittyMail::Util.safe_json(mail&.from, on_error: "encoding error for 'from' during logging; subject: #{subj}", strict_errors: strict_errors)
  suffix = begin
    date = mail&.date
    "sent on #{date}"
  rescue Mail::Field::NilParseError, ArgumentError
    raise if strict_errors
    "sent on unknown date"
  end
  line = "processing mail in mailbox #{mbox_name} with uid: #{uid} from #{from} and subject: #{subj} #{flags_json} #{suffix}"
  if progress
    progress.log(line)
  else
    puts line
  end
end

module NittyMail
  class Sync
    def self.perform(settings_or_options)
      if settings_or_options.is_a?(SyncSettings::Settings)
        new.perform_sync(settings_or_options)
      else
        # Legacy support: if passed a hash with keyword arguments, create Settings object
        new.perform_sync(SyncSettings::Settings.new(**settings_or_options))
      end
    end

    def perform_sync(settings)
      @strict_errors = !!settings.strict_errors
      @retry_attempts = settings.retry_attempts.to_i
      @prune_missing = !!settings.prune_missing
      @quiet = !!settings.quiet

      # Ensure threads count is valid
      threads_count = (settings.threads_count < 1) ? 1 : settings.threads_count
      fetch_batch_size = (settings.fetch_batch_size.to_i < 1) ? 1 : settings.fetch_batch_size.to_i
      Thread.abort_on_exception = true if threads_count > 1

      Mail.defaults do
        retriever_method :imap, address: "imap.gmail.com",
          port: 993,
          user_name: settings.imap_address,
          password: settings.imap_password,
          enable_ssl: true
      end

      @db = NittyMail::DB.connect(settings.database_path, wal: settings.sqlite_wal, load_vec: false)
      email = NittyMail::DB.ensure_schema!(@db)
      NittyMail::DB.ensure_query_indexes!(@db)

      reporter = settings.reporter || NittyMail::Reporting::NullReporter.new(quiet: settings.quiet, on_progress: settings.on_progress)

      # get all mailboxes
      mailboxes = Mail.connection { |imap| imap.list "", "*" }
      selectable_mailboxes = mailboxes.reject { |mb| mb.attr.include?(:Noselect) }

      # Apply mailbox filters
      only_mailboxes = (settings.only_mailboxes || []).compact.map(&:to_s).map(&:strip).reject(&:empty?)
      ignore_mailboxes = (settings.ignore_mailboxes || []).compact.map(&:to_s).map(&:strip).reject(&:empty?)

      selectable_mailboxes = filter_mailboxes_by_only_list(selectable_mailboxes, only_mailboxes)
      selectable_mailboxes = filter_mailboxes_by_ignore_list(selectable_mailboxes, ignore_mailboxes)

      # Preflight mailbox checks (uidvalidity and UID diff) in parallel
      mailbox_threads = settings.mailbox_threads.to_i
      mailbox_threads = 1 if mailbox_threads < 1

      preflight_results = []
      preflight_mutex = Mutex.new
      db_mutex = Mutex.new

      # Use a queue to distribute work across mailbox preflight threads
      mbox_queue = Queue.new
      selectable_mailboxes.each { |mb| mbox_queue << mb }

      thread_word = (mailbox_threads == 1) ? "thread" : "threads"
      reporter.info("preflighting #{selectable_mailboxes.size} mailboxes with #{mailbox_threads} #{thread_word}")
      reporter.start(title: "preflight", total: selectable_mailboxes.size)

      preflight_workers = Array.new([mailbox_threads, selectable_mailboxes.size].min) do
        Thread.new do
          run_preflight_worker(settings.imap_address, settings.imap_password, email, mbox_queue, preflight_results, preflight_mutex, reporter, db_mutex)
        end
      end
      preflight_workers.each(&:join)
      reporter.finish

      # Process each mailbox (sequentially) using preflight results
      preflight_results.each do |preflight_result|
        process_mailbox(preflight_result, settings, email, threads_count, fetch_batch_size, reporter)
      end
    end

    private

    def run_preflight_worker(imap_address, imap_password, email, mbox_queue, preflight_results, preflight_mutex, preflight_progress, db_mutex)
      # Each preflight thread uses its own IMAP connection
      imap = Net::IMAP.new("imap.gmail.com", port: 993, ssl: true)
      imap.login(imap_address, imap_password)
      loop do
        mailbox = begin
          mbox_queue.pop(true)
        rescue ThreadError
          nil
        end
        break unless mailbox

        mbox_name = mailbox.name
        pfcalc = NittyMail::Preflight.compute(imap, email, mbox_name, db_mutex)
        uidvalidity = pfcalc[:uidvalidity]
        uids = pfcalc[:to_fetch]
        db_only = pfcalc[:db_only]
        server_size = pfcalc[:server_size]
        db_size = pfcalc[:db_size]

        preflight_mutex.synchronize do
          preflight_results << {name: mbox_name, uidvalidity:, uids:, db_only:}
          # Log counts
          preflight_progress.log("#{mbox_name}: uidvalidity=#{uidvalidity}, to_fetch=#{uids.size}, to_prune=#{db_only.size} (server=#{server_size}, db=#{db_size})")
          # Log preview of UIDs to be synced (first 5, then summary)
          preflight_progress.log(NittyMail::Logging.format_uids_preview(uids))
          # If pruning is disabled but we detected candidates, inform the user upfront
          if !@prune_missing && db_only.any?
            preflight_progress.log("prune candidates present: #{db_only.size} (prune disabled; no pruning will be performed)")
          end
          preflight_progress.increment
        end
      end
      imap.logout
      imap.disconnect
    end

    def process_mailbox(preflight_result, settings, email, threads_count, fetch_batch_size, reporter)
      mbox_name = preflight_result[:name]
      uidvalidity = preflight_result[:uidvalidity]
      uids = preflight_result[:uids]

      # Skip mailboxes with nothing to fetch
      if uids.nil? || uids.empty?
        reporter.info("skipping mailbox #{mbox_name} (nothing to fetch)")
        reporter.info("")
        return
      end

      reporter.info("processing mailbox #{mbox_name}")
      reporter.info("uidvalidity is #{uidvalidity}")
      thread_word = (threads_count == 1) ? "thread" : "threads"
      reporter.info("processing #{uids.size} uids in #{mbox_name} with #{threads_count} #{thread_word}")
      reporter.start(title: "#{mbox_name} (UIDVALIDITY=#{uidvalidity})", total: uids.size)

      result = NittyMail::MailboxRunner.run(
        settings:,
        email_ds: email,
        mbox_name:,
        uidvalidity:,
        uids:,
        threads_count:,
        fetch_batch_size:,
        progress: reporter
      )

      # Handle pruning and purging operations
      db_only = preflight_result[:db_only] || []
      handle_prune_missing(mbox_name, uidvalidity, db_only, result, reporter)
      handle_purge_old_validity(email, settings, mbox_name, uidvalidity, reporter)
      reporter.finish
      reporter.info("")
    end

    private

    def handle_prune_missing(mbox_name, uidvalidity, db_only, result, reporter)
      if @prune_missing && result != :aborted
        if db_only.any?
          count = @db.transaction do
            NittyMail::DB.prune_missing!(@db, mbox_name, uidvalidity, db_only)
          end
          reporter.info("Pruned #{count} row(s) missing on server from '#{mbox_name}' (UIDVALIDITY=#{uidvalidity})")
        else
          reporter.info("No rows to prune for '#{mbox_name}'")
        end
      elsif @prune_missing && result == :aborted
        reporter.info("Skipped pruning for '#{mbox_name}' due to mailbox abort")
      elsif !@prune_missing && db_only.any?
        reporter.info("Detected #{db_only.size} prune candidate(s) for '#{mbox_name}', but --prune-missing is disabled; no pruning performed")
      end
    end

    def handle_purge_old_validity(email, settings, mbox_name, uidvalidity, reporter)
      other_validities = email.where(mailbox: mbox_name).exclude(uidvalidity: uidvalidity).distinct.select_map(:uidvalidity)
      return if other_validities.empty?

      do_purge = false
      if settings.purge_old_validity
        do_purge = true
      elsif $stdin.tty? && !settings.auto_confirm
        print "Detected old UIDVALIDITY data for '#{mbox_name}' (#{other_validities.join(", ")}). Purge now? [y/N]: "
        ans = $stdin.gets&.strip&.downcase
        do_purge = %w[y yes].include?(ans)
      end

      if do_purge
        count = email.where(mailbox: mbox_name).exclude(uidvalidity: uidvalidity).count
        @db.transaction do
          email.where(mailbox: mbox_name).exclude(uidvalidity: uidvalidity).delete
        end
        reporter.info("Purged #{count} rows from mailbox '#{mbox_name}' with old UIDVALIDITY values")
      else
        reporter.info("Skipped purging old UIDVALIDITY rows for '#{mbox_name}'")
      end
    end

    def filter_mailboxes_by_only_list(selectable_mailboxes, only_mailboxes)
      return selectable_mailboxes if only_mailboxes.empty?

      include_regexes = only_mailboxes.map do |pat|
        escaped = Regexp.escape(pat)
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
      return selectable_mailboxes if ignore_mailboxes.empty?

      regexes = ignore_mailboxes.map do |pat|
        escaped = Regexp.escape(pat)
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
  end
end
