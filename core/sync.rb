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
require "dotenv/load"
require "debug"
require "mail"
require "sequel"
require "json"

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

# IMAP
imap_address = ENV["ADDRESS"]
imap_password = ENV["PASSWORD"]
Mail.defaults do
  retriever_method :imap, address: "imap.gmail.com",
    port: 993,
    user_name: imap_address,
    password: imap_password,
    enable_ssl: true
end

DB = Sequel.sqlite(ENV["DATABASE"])

unless DB.table_exists?(:email)
  DB.create_table :email do
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

email = DB[:email]

# get all mailboxes
mailboxes = Mail.connection { |imap| imap.list "", "*" }
mailboxes.each do |mailbox|
  # mailboxes with attr :Noselect cannpt be selected so we skip those
  next if mailbox.attr.include?(:Noselect)

  mbox_name = mailbox.name
  puts "processing mailbox #{mbox_name}"

  # get the max uid for a mailbox, paying attention to the uidvalidity
  # we have to "throw away" the cached records if the uidvalidity changes
  uidvalidity = max_uid = 1
  Mail.connection do |imap|
    imap.select(mbox_name)
    uidvalidity = imap.responses["UIDVALIDITY"]&.first || 1
    max_uid = email.where(mailbox: mbox_name, uidvalidity: uidvalidity).count || 1
    max_uid = 1 if max_uid.zero? # minimum for imap key search is 1
    puts "uidvalidty is #{uidvalidity} and max_uid is #{max_uid}"
  end

  Mail.find read_only: true, count: :all, mailbox: mbox_name, keys: "#{max_uid}:*" do |mail, imap, uid|
    # patch in Gmail specific extesnions
    patch(imap)
    x_gm_labels = imap.uid_fetch(uid, ["X-GM-LABELS"]).first.attr["X-GM-LABELS"].to_s
    x_gm_msgid = imap.uid_fetch(uid, ["X-GM-MSGID"]).first.attr["X-GM-MSGID"].to_s
    x_gm_thrid = imap.uid_fetch(uid, ["X-GM-THRID"]).first.attr["X-GM-THRID"].to_s

    flags = imap.uid_fetch(uid, ["FLAGS"]).first.attr["FLAGS"].to_json

    begin
      puts "processing mail in mailbox #{mbox_name} with uid: #{uid} sent on #{mail.date} from #{mail.from.to_json} and subject: #{mail.subject} #{flags}"
    rescue Mail::Field::NilParseError => e
      puts e.inspect
      puts mail
      mail.date = nil
    end

    begin
      email.insert(
        address: imap_address,
        mailbox: mbox_name.force_encoding("UTF-8"),
        uid: uid,
        uidvalidity: uidvalidity,

        message_id: mail.message_id&.force_encoding("UTF-8"),
        date: mail.date,
        from: mail.from.to_json.force_encoding("UTF-8"),
        subject: mail.subject&.force_encoding("UTF-8"), # subject can be nil
        has_attachments: mail.has_attachments?,

        x_gm_labels: x_gm_labels.force_encoding("UTF-8"),
        x_gm_msgid: x_gm_msgid.force_encoding("UTF-8"),
        x_gm_thrid: x_gm_thrid.force_encoding("UTF-8"),
        flags: flags.force_encoding("UTF-8"),

        encoded: mail.encoded
          .force_encoding("UTF-8")
          .encode("UTF-8", "binary", invalid: :replace, undef: :replace, replace: "") # fix `invalid byte sequence in UTF-8`
      )
    rescue Sequel::UniqueConstraintViolation
      puts "#{mbox_name} #{uid} #{uidvalidity} already exists, skipping ..."
    rescue => e
      puts mail.inspect
      puts e.inspect
      raise
    end
  end
  puts
end
