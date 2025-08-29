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

# Ensure immediate flushing so output appears promptly in Docker
$stdout.sync = true

# Format a concise preview of UIDs slated for syncing
def format_uids_preview(uids)
  return "uids to be synced: []" if uids.nil? || uids.empty?
  preview_count = [uids.size, 5].min
  preview = uids.first(preview_count).join(", ")
  more = uids.size - preview_count
  suffix = (more > 0) ? ", ... (#{more} more uids)" : ""
  "uids to be synced: [#{preview}#{suffix}]"
end

# patch only this instance of Net::IMAP::ResponseParser
def patch(gmail_imap)
  class << gmail_imap.instance_variable_get(:@parser)
    # copied from https://github.com/ruby/net-imap/blob/master/lib/net/imap/response_parser.rb#L193
    def msg_att(n)
      match(T_LPAR)
      attr = {}
      loop do
        token = lookahead
        case token.symbol
        when T_RPAR
          shift_token
          break
        when T_SPACE
          shift_token
          next
        end
        case token.value
        when /\A(?:ENVELOPE)\z/ni
          name, val = envelope_data
        when /\A(?:FLAGS)\z/ni
          name, val = flags_data
        when /\A(?:INTERNALDATE)\z/ni
          name, val = internaldate_data
        when /\A(?:RFC822(?:\.HEADER|\.TEXT)?)\z/ni
          name, val = rfc822_text
        when /\A(?:RFC822\.SIZE)\z/ni
          name, val = rfc822_size
        when /\A(?:BODY(?:STRUCTURE)?)\z/ni
          name, val = body_data
        when /\A(?:UID)\z/ni
          name, val = uid_data
        when /\A(?:MODSEQ)\z/ni
          name, val = modseq_data

        # adding in Gmail extended attributes
        # see https://gist.github.com/kellyredding/2712611
        when /\A(?:X-GM-LABELS)\z/ni
          name, val = flags_data
        when /\A(?:X-GM-MSGID)\z/ni
          name, val = uid_data
        when /\A(?:X-GM-THRID)\z/ni
          name, val = uid_data

        else
          parse_error("unknown attribute `%s' for {%d}", token.value, n)
        end
        attr[name] = val
      end
      attr
    end
  end
  gmail_imap
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

      unless @db.table_exists?(:email)
        @db.create_table :email do
          primary_key :id
          String :address, index: true
          String :mailbox, index: true
          Bignum :uid, index: true, default: 0
          Integer :uidvalidity, index: true, default: 0

          String :message_id, index: true
          DateTime :date, index: true
          String :from, index: true
          String :subject

          Boolean :has_attachments, index: true, default: false

          String :x_gm_labels
          String :x_gm_msgid
          String :x_gm_thrid
          String :flags

          String :encoded

          unique %i[mailbox uid uidvalidity]
          index %i[mailbox uidvalidity]
        end
      end

      email = @db[:email]

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
            imap.examine(mbox_name)
            uidvalidity = imap.responses["UIDVALIDITY"]&.first
            raise "UIDVALIDITY missing for mailbox #{mbox_name}" if uidvalidity.nil?

            # Server-diff: compute UIDs that are on server but not in DB
            server_uids = imap.uid_search("UID 1:*")
            db_uids = db_mutex.synchronize do
              email.where(mailbox: mbox_name, uidvalidity: uidvalidity).select_map(:uid)
            end
            uids = server_uids - db_uids
            db_only = db_uids - server_uids

            preflight_mutex.synchronize do
              preflight_results << {name: mbox_name, uidvalidity: uidvalidity, uids: uids, db_only: db_only}
              # Log counts
              preflight_progress.log("#{mbox_name}: uidvalidity=#{uidvalidity}, to_fetch=#{uids.size}, to_prune=#{db_only.size} (server=#{server_uids.size}, db=#{db_uids.size})")
              # Log preview of UIDs to be synced (first 5, then summary)
              preflight_progress.log(format_uids_preview(uids))
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

        # Build batches to reduce round-trips
        batch_queue = Queue.new
        uids.each_slice(fetch_batch_size) { |batch| batch_queue << batch }

        write_queue = Queue.new

        # If set to true, all workers will stop processing this mailbox
        mailbox_abort = false

        # Use a prepared insert with bind parameters to safely handle
        # any bytes/newlines/quotes in values (especially large bodies).
        insert_stmt = email.prepare(
          :insert, :insert_email,
          address: :$address,
          mailbox: :$mailbox,
          uid: :$uid,
          uidvalidity: :$uidvalidity,
          message_id: :$message_id,
          date: :$date,
          from: :$from,
          subject: :$subject,
          has_attachments: :$has_attachments,
          x_gm_labels: :$x_gm_labels,
          x_gm_msgid: :$x_gm_msgid,
          x_gm_thrid: :$x_gm_thrid,
          flags: :$flags,
          encoded: :$encoded
        )

        writer = Thread.new do
          loop do
            rec = write_queue.pop
            break if rec == :__DONE__

            begin
              insert_stmt.call(rec)
            rescue Sequel::UniqueConstraintViolation => e
              raise e if @strict_errors
              # Log through the progress bar to avoid clobbering
              progress.log("#{rec[:mailbox]} #{rec[:uid]} #{rec[:uidvalidity]} already exists, skipping ...")
            end
            progress.increment
          end
        end

        workers = Array.new(threads_count) do
          Thread.new do
            # Helper to (re)connect IMAP and select mailbox
            reconnect = proc do
              if defined?(imap) && imap
                begin
                  imap.logout
                  imap.disconnect
                rescue
                end
              end

              imap = Net::IMAP.new("imap.gmail.com", port: 993, ssl: true)
              imap.login(imap_address, imap_password)
              # Use read-only EXAMINE to avoid changing flags like \\Seen
              imap.examine(mbox_name)
              patch(imap)
              worker_uidvalidity = imap.responses["UIDVALIDITY"]&.first
              raise "UIDVALIDITY missing for mailbox #{mbox_name} in worker" if worker_uidvalidity.nil?
              if worker_uidvalidity.to_i != uidvalidity.to_i
                raise "UIDVALIDITY changed for mailbox #{mbox_name} (preflight=#{uidvalidity}, worker=#{worker_uidvalidity}). Please rerun."
              end
              imap
            end

            imap = reconnect.call
            loop do
              break if mailbox_abort
              batch = begin
                batch_queue.pop(true)
              rescue ThreadError
                nil
              end
              break unless batch

              # Fetch multiple messages at once; BODY.PEEK[] avoids setting \\Seen
              fetch_items = ["BODY.PEEK[]", "X-GM-LABELS", "X-GM-MSGID", "X-GM-THRID", "FLAGS", "UID"]
              attempts = 0
              fetched = []
              begin
                attempts += 1
                fetched = imap.uid_fetch(batch, fetch_items) || []
              rescue OpenSSL::SSL::SSLError, IOError => e
                progress.log("IMAP read error (#{e.class}: #{e.message}) on #{mbox_name}; retrying (attempt #{attempts})...")
                # Retry indefinitely only when set to -1. If 0, do not retry.
                if @retry_attempts == -1 || attempts < @retry_attempts
                  sleep 1 * attempts
                  imap = reconnect.call
                  retry
                else
                  # Exhausted retries: abort this mailbox and proceed to the next one
                  mailbox_abort = true
                  progress.log("Aborting mailbox '#{mbox_name}' after #{attempts} failed attempt(s); proceeding to next mailbox")
                  break
                end
              end
              fetched.each do |fd|
                attrs = fd.attr
                next unless attrs
                uid = attrs["UID"]
                raw = attrs["BODY[]"] || attrs["RFC822"]
                mail = NittyMail::Util.parse_mail_safely(raw, mbox_name: mbox_name, uid: uid)
                flags_json = attrs["FLAGS"].to_json
                log_processing(mbox_name:, uid:, mail:, flags_json:, raw: raw, progress: progress, strict_errors: @strict_errors)
                rec = build_record(
                  imap_address:,
                  mbox_name:,
                  uid:,
                  uidvalidity:,
                  mail:,
                  attrs:,
                  flags_json:,
                  raw: raw,
                  strict_errors: @strict_errors
                )
                write_queue << rec
              end
            end
            imap.logout
            imap.disconnect
          end
        end

        workers.each(&:join)
        write_queue << :__DONE__
        writer.join

        # Optionally prune rows that no longer exist on the server for this mailbox
        if @prune_missing && !mailbox_abort
          db_only = pf[:db_only] || []
          if db_only.any?
            count = db_only.size
            @db.transaction do
              email.where(mailbox: mbox_name, uidvalidity: uidvalidity, uid: db_only).delete
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
