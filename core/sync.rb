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
require "ruby-progressbar"

# Ensure immediate flushing so output appears promptly in Docker
$stdout.sync = true

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
def build_record(imap_address:, mbox_name:, uid:, uidvalidity:, mail:, attrs:, flags_json:)
  date = begin
    mail&.date
  rescue Mail::Field::NilParseError
    puts "Error parsing date for #{mail&.subject}"
    nil
  end

  {
    address: imap_address,
    mailbox: mbox_name.force_encoding("UTF-8"),
    uid: uid,
    uidvalidity: uidvalidity,

    message_id: mail&.message_id&.force_encoding("UTF-8"),
    date:,
    from: mail&.from&.to_json&.force_encoding("UTF-8"),
    subject: mail&.subject&.force_encoding("UTF-8"),
    has_attachments: mail ? mail.has_attachments? : false,

    x_gm_labels: attrs["X-GM-LABELS"].to_s.force_encoding("UTF-8"),
    x_gm_msgid: attrs["X-GM-MSGID"].to_s.force_encoding("UTF-8"),
    x_gm_thrid: attrs["X-GM-THRID"].to_s.force_encoding("UTF-8"),
    flags: flags_json.force_encoding("UTF-8"),

    encoded: (mail ? mail.encoded : attrs["RFC822"])
      .to_s
      .force_encoding("UTF-8")
      .encode("UTF-8", "binary", invalid: :replace, undef: :replace, replace: "")
  }
end

# Log a concise processing line (handles odd headers safely)
def log_processing(mbox_name:, uid:, mail:, flags_json:)
  subj = mail&.subject
  from = mail&.from&.to_json
  print "processing mail in mailbox #{mbox_name} with uid: #{uid} from #{from} and subject: #{subj} #{flags_json} "

  date = mail&.date
  puts "sent on #{date}"
rescue Mail::Field::NilParseError
  puts "sent on unknown date"
end

module NittyMail
  class Sync
    def self.perform(imap_address:, imap_password:, database_path:, threads_count: 1, mailbox_threads: 1)
      new.perform_sync(imap_address, imap_password, database_path, threads_count, mailbox_threads)
    end

    def perform_sync(imap_address, imap_password, database_path, threads_count, mailbox_threads)
      # Ensure threads count is valid
      threads_count = 1 if threads_count < 1
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

      # Preflight mailbox checks (uidvalidity, max_uid, and UID list) in parallel
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
            imap.select(mbox_name)
            uidvalidity = imap.responses["UIDVALIDITY"]&.first || 1
            max_uid = db_mutex.synchronize do
              email.where(mailbox: mbox_name, uidvalidity: uidvalidity).max(:uid)
            end
            max_uid = 1 if max_uid.nil? || max_uid.to_i < 1
            uids = imap.uid_search("UID #{max_uid}:*")

            preflight_mutex.synchronize do
              preflight_results << {name: mbox_name, uidvalidity: uidvalidity, max_uid: max_uid, uids: uids}
              preflight_progress.log("#{mbox_name}: uidvalidity=#{uidvalidity}, from_uid=#{max_uid}, found=#{uids.size}")
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
        max_uid = pf[:max_uid]

        puts "processing mailbox #{mbox_name}"
        puts "uidvalidty is #{uidvalidity} and max_uid is #{max_uid}"
        thread_word = (threads_count == 1) ? "thread" : "threads"
        puts "processing #{uids.size} uids in #{mbox_name} with #{threads_count} #{thread_word}"

        progress = ProgressBar.create(
          title: mbox_name,
          total: uids.size,
          format: "%t: |%B| %p%% (%c/%C) [%e]"
        )

        uid_queue = Queue.new
        uids.each { |u| uid_queue << u }

        write_queue = Queue.new

        writer = Thread.new do
          loop do
            rec = write_queue.pop
            break if rec == :__DONE__

            begin
              email.insert(rec)
            rescue Sequel::UniqueConstraintViolation
              puts "#{rec[:mailbox]} #{rec[:uid]} #{rec[:uidvalidity]} already exists, skipping ..."
            end
            progress.increment
          end
        end

        workers = Array.new(threads_count) do
          Thread.new do
            imap = Net::IMAP.new("imap.gmail.com", port: 993, ssl: true)
            imap.login(imap_address, imap_password)
            imap.select(mbox_name)
            patch(imap)
            loop do
              begin
                uid = uid_queue.pop(true)
              rescue ThreadError
                uid = nil
              end
              break unless uid

              attrs = imap.uid_fetch(uid, %w[RFC822 X-GM-LABELS X-GM-MSGID X-GM-THRID FLAGS]).first&.attr
              next unless attrs

              mail = Mail.read_from_string(attrs["RFC822"])
              flags_json = attrs["FLAGS"].to_json
              log_processing(mbox_name:, uid:, mail:, flags_json:)
              rec = build_record(
                imap_address:,
                mbox_name:,
                uid:,
                uidvalidity:,
                mail:,
                attrs:,
                flags_json:
              )
              write_queue << rec
            end
            imap.logout
            imap.disconnect
          end
        end

        workers.each(&:join)
        write_queue << :__DONE__
        writer.join
        puts
      end
    end
  end
end
