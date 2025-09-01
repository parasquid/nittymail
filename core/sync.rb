#!/usr/bin/env ruby
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
require_relative "lib/nittymail/sync_utils"

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

      selectable_mailboxes = NittyMail::SyncUtils.filter_mailboxes_by_only_list(selectable_mailboxes, only_mailboxes)
      selectable_mailboxes = NittyMail::SyncUtils.filter_mailboxes_by_ignore_list(selectable_mailboxes, ignore_mailboxes)

      # Preflight mailbox checks (uidvalidity and UID diff) in parallel
      mailbox_threads = settings.mailbox_threads.to_i
      mailbox_threads = 1 if mailbox_threads < 1

      preflight_results = []
      preflight_mutex = Mutex.new
      db_mutex = Mutex.new

      # Use a queue to distribute work across mailbox preflight threads
      mbox_queue = Queue.new
      selectable_mailboxes.each { |mb| mbox_queue << mb }

      # emit preflight start event (thread count included)
      reporter.event(:preflight_started, {total_mailboxes: selectable_mailboxes.size, threads: mailbox_threads})

      preflight_workers = Array.new([mailbox_threads, selectable_mailboxes.size].min) do
        Thread.new do
          run_preflight_worker(settings.imap_address, settings.imap_password, email, mbox_queue, preflight_results, preflight_mutex, reporter, db_mutex)
        end
      end
      preflight_workers.each(&:join)
      reporter.event(:preflight_finished, {mailboxes: selectable_mailboxes.size})

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
      while (mailbox = begin
        mbox_queue.pop(true)
      rescue
        nil
      end)

        mbox_name = mailbox.name
        pfcalc = NittyMail::Preflight.compute(imap, email, mbox_name, db_mutex)
        uidvalidity = pfcalc[:uidvalidity]
        uids = pfcalc[:to_fetch]
        db_only = pfcalc[:db_only]
        server_size = pfcalc[:server_size]
        db_size = pfcalc[:db_size]

        preflight_mutex.synchronize do
          preflight_results << {name: mbox_name, uidvalidity:, uids:, db_only:}
          preflight_progress.event(:preflight_mailbox, {mailbox: mbox_name, uidvalidity: uidvalidity, to_fetch: uids.size, to_prune: db_only.size, server_size:, db_size:, uids_preview: NittyMail::Logging.format_uids_preview(uids)})
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
        reporter.event(:mailbox_skipped, {mailbox: mbox_name, reason: :nothing_to_fetch})
        return
      end

      thread_word = (threads_count == 1) ? "thread" : "threads"
      reporter.event(:mailbox_started, {mailbox: mbox_name, uidvalidity: uidvalidity, total: uids.size, threads: threads_count, thread_word: thread_word})

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
      status = result.is_a?(Hash) ? result[:status] : result
      processed_msgs = result.is_a?(Hash) ? (result[:processed] || uids.size) : uids.size
      error_count = result.is_a?(Hash) ? (result[:errors] || 0) : 0
      pruned_count = NittyMail::SyncUtils.handle_prune_missing(@db, @prune_missing, status, mbox_name, uidvalidity, db_only, reporter)
      purged_count = NittyMail::SyncUtils.handle_purge_old_validity(@db, email, settings, mbox_name, uidvalidity, reporter)
      reporter.event(:mailbox_summary, {
        mailbox: mbox_name,
        uidvalidity: uidvalidity,
        total: uids.size,
        prune_candidates: db_only.size,
        pruned: pruned_count || 0,
        purged: purged_count || 0,
        processed: processed_msgs,
        errors: error_count,
        result: status
      })
      reporter.event(:mailbox_finished, {mailbox: mbox_name, uidvalidity: uidvalidity, processed: processed_msgs, result: status})
    end

    private

    # extracted helpers now live in NittyMail::SyncUtils
  end
end
