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

# Ensure immediate flushing so output appears promptly in Docker
$stdout.sync = true

# format moved to NittyMail::Logging

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
    mailbox: safe_utf8(mbox_name),
    uid: uid,
    uidvalidity: uidvalidity,

    message_id: NittyMail::Util.safe_utf8(mail&.message_id),
    date:,
    from: begin
      NittyMail::Util.safe_json(mail&.from, strict_errors: strict_errors)
    rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      raise if strict_errors
      warn "encoding error for 'from' while building record; subject: #{subject_str}"
      "[]"
    end,
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
  from = begin
    NittyMail::Util.safe_json(mail&.from, on_error: "encoding error for 'from' during logging; subject: #{subj}", strict_errors: strict_errors)
  rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    raise if strict_errors
    warn "encoding error for 'from' during logging; subject: #{subj}"
    "[]"
  end
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
    def self.perform(imap_address:, imap_password:, database_path:, threads_count: 1, mailbox_threads: 1, purge_old_validity: false, auto_confirm: false, fetch_batch_size: 100, ignore_mailboxes: [], strict_errors: false, retry_attempts: 3, prune_missing: false)
      new.perform_sync(imap_address, imap_password, database_path, threads_count, mailbox_threads, purge_old_validity, auto_confirm, fetch_batch_size, ignore_mailboxes, strict_errors, retry_attempts, prune_missing)
    end

    def perform_sync(imap_address, imap_password, database_path, threads_count, mailbox_threads, purge_old_validity, auto_confirm, fetch_batch_size, ignore_mailboxes, strict_errors, retry_attempts, prune_missing)
      @strict_errors = !!strict_errors
      @retry_attempts = retry_attempts.to_i
      @prune_missing = !!prune_missing
      # Ensure threads count is valid
      threads_count = 1 if threads_count < 1
      fetch_batch_size = 1 if fetch_batch_size.to_i < 1
      Thread.abort_on_exception = true if threads_count > 1
      Mail.defaults do
        retriever_method :imap, address: "imap.gmail.com",
          port: 993,
          user_name: imap_address,
          password: imap_password,
          enable_ssl: true
      end

      @db = Sequel.sqlite(database_path)
      email = NittyMail::DB.ensure_schema!(@db)

      # get all mailboxes
      mailboxes = Mail.connection { |imap| imap.list "", "*" }
      selectable_mailboxes = mailboxes.reject { |mb| mb.attr.include?(:Noselect) }

      # Filter out ignored mailboxes if configured
      ignore_mailboxes ||= []
      ignore_mailboxes = ignore_mailboxes.compact.map(&:to_s).map(&:strip).reject(&:empty?)
      if ignore_mailboxes.any?
        # Convert simple glob patterns (* and ?) to regex safely
        regexes = ignore_mailboxes.map do |pat|
          escaped = Regexp.escape(pat)
          escaped = escaped.gsub(/\\\*/m, ".*")
          escaped = escaped.gsub(/\\\?/m, ".")
          Regexp.new("^#{escaped}$", Regexp::IGNORECASE)
        end

        before = selectable_mailboxes.size
        ignored, kept = selectable_mailboxes.partition { |mb| regexes.any? { |rx| rx.match?(mb.name) } }
        selectable_mailboxes = kept
        if ignored.any?
          ignored_names = ignored.map(&:name)
          puts "ignoring #{ignored_names.size} mailbox(es): #{ignored_names.join(", ")}"
        end
        puts "will consider #{selectable_mailboxes.size} selectable mailbox(es) after ignore filter (was #{before})"
      end

      # Preflight mailbox checks (uidvalidity and UID diff) in parallel
      mailbox_threads = mailbox_threads.to_i
      mailbox_threads = 1 if mailbox_threads < 1

      preflight_results = []
      preflight_mutex = Mutex.new
      db_mutex = Mutex.new

      # Use a queue to distribute work across mailbox preflight threads
      mbox_queue = Queue.new
      selectable_mailboxes.each { |mb| mbox_queue << mb }

      thread_word = (mailbox_threads == 1) ? "thread" : "threads"
      puts "preflighting #{selectable_mailboxes.size} mailboxes with #{mailbox_threads} #{thread_word}"
      preflight_progress = ProgressBar.create(
        title: "preflight",
        total: selectable_mailboxes.size,
        format: "%t: |%B| %p%% (%c/%C) [%e]"
      )

      preflight_workers = Array.new([mailbox_threads, selectable_mailboxes.size].min) do
        Thread.new do
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
              preflight_results << {name: mbox_name, uidvalidity: uidvalidity, uids: uids, db_only: db_only}
              # Log counts
              preflight_progress.log("#{mbox_name}: uidvalidity=#{uidvalidity}, to_fetch=#{uids.size}, to_prune=#{db_only.size} (server=#{server_size}, db=#{db_size})")
              # Log preview of UIDs to be synced (first 5, then summary)
              preflight_progress.log(NittyMail::Logging.format_uids_preview(uids))
              preflight_progress.increment
            end
          end
          imap.logout
          imap.disconnect
        end
      end
      preflight_workers.each(&:join)

      puts

      # Process each mailbox (sequentially) using preflight results
      preflight_results.each do |pf|
        mbox_name = pf[:name]
        uidvalidity = pf[:uidvalidity]
        uids = pf[:uids]
        # Skip mailboxes with nothing to fetch
        if uids.nil? || uids.empty?
          puts "skipping mailbox #{mbox_name} (nothing to fetch)"
          puts
          next
        end

        puts "processing mailbox #{mbox_name}"
        puts "uidvalidity is #{uidvalidity}"
        thread_word = (threads_count == 1) ? "thread" : "threads"
        puts "processing #{uids.size} uids in #{mbox_name} with #{threads_count} #{thread_word}"

        progress = ProgressBar.create(
          title: "#{mbox_name} (UIDVALIDITY=#{uidvalidity})",
          total: uids.size,
          format: "%t: |%B| %p%% (%c/%C) [%e]"
        )

        result = NittyMail::MailboxRunner.run(
          imap_address:,
          imap_password:,
          email_ds: email,
          mbox_name:,
          uidvalidity:,
          uids:,
          threads_count:,
          fetch_batch_size:,
          retry_attempts: @retry_attempts,
          strict_errors: @strict_errors,
          progress:
        )

        # Optionally prune rows that no longer exist on the server for this mailbox
        if @prune_missing && result != :aborted
          db_only = pf[:db_only] || []
          if db_only.any?
            count = @db.transaction do
              NittyMail::DB.prune_missing!(@db, mbox_name, uidvalidity, db_only)
            end
            puts "Pruned #{count} row(s) missing on server from '#{mbox_name}' (UIDVALIDITY=#{uidvalidity})"
          else
            puts "No rows to prune for '#{mbox_name}'"
          end
        elsif @prune_missing && mailbox_abort
          puts "Skipped pruning for '#{mbox_name}' due to mailbox abort"
        end
        # Optionally purge old UIDVALIDITY generations for this mailbox
        other_validities = email.where(mailbox: mbox_name).exclude(uidvalidity: uidvalidity).distinct.select_map(:uidvalidity)
        unless other_validities.empty?
          do_purge = false
          if purge_old_validity
            do_purge = true
          elsif $stdin.tty? && !auto_confirm
            print "Detected old UIDVALIDITY data for '#{mbox_name}' (#{other_validities.join(", ")}). Purge now? [y/N]: "
            ans = $stdin.gets&.strip&.downcase
            do_purge = %w[y yes].include?(ans)
          end
          if do_purge
            count = email.where(mailbox: mbox_name).exclude(uidvalidity: uidvalidity).count
            @db.transaction do
              email.where(mailbox: mbox_name).exclude(uidvalidity: uidvalidity).delete
            end
            puts "Purged #{count} rows from mailbox '#{mbox_name}' with old UIDVALIDITY values"
          else
            puts "Skipped purging old UIDVALIDITY rows for '#{mbox_name}'"
          end
        end
        puts
      end
    end
  end
end
