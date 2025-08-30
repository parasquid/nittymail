#!/usr/bin/env ruby
# frozen_string_literal: true

require "sequel"
require "ruby-progressbar"
require_relative "lib/nittymail/util"
require_relative "lib/nittymail/db"

module NittyMail
  class Enrich
    def self.perform(database_path:, address_filter: nil, limit: nil, offset: nil, quiet: false)
      raise ArgumentError, "database_path is required" if database_path.to_s.strip.empty?

      db = NittyMail::DB.connect(database_path, wal: true, load_vec: false)
      email_ds = NittyMail::DB.ensure_schema!(db)
      NittyMail::DB.ensure_enrichment_columns!(db)

      ds = email_ds
      ds = ds.where(address: address_filter) if address_filter && !address_filter.to_s.strip.empty?
      ds = ds.offset(offset.to_i) if offset && offset.to_i > 0
      ds = ds.limit(limit.to_i) if limit && limit.to_i > 0

      total = ds.count
      puts "Enriching #{total} email(s)#{address_filter ? " for #{address_filter}" : ""} from stored raw messages" unless quiet

      progress = ProgressBar.create(title: "enrich", total: total, format: "%t: |%B| %p%% (%c/%C) [%e]")
      ds.each do |row|
        raw = row[:encoded]
        mail = NittyMail::Util.parse_mail_safely(raw, mbox_name: row[:mailbox], uid: row[:uid])

        # Reconstruct envelope
        env_to = NittyMail::Util.safe_json(mail&.to)
        env_cc = NittyMail::Util.safe_json(mail&.cc)
        env_bcc = NittyMail::Util.safe_json(mail&.bcc)
        env_reply_to = NittyMail::Util.safe_json(mail&.reply_to)
        in_reply_to = NittyMail::Util.safe_utf8(mail&.in_reply_to)
        references = NittyMail::Util.safe_json(mail&.references)

        # RFC822 size from raw bytes
        rfc822_size = raw&.bytesize

        updates = {
          rfc822_size: rfc822_size,
          envelope_to: env_to,
          envelope_cc: env_cc,
          envelope_bcc: env_bcc,
          envelope_reply_to: env_reply_to,
          envelope_in_reply_to: in_reply_to,
          envelope_references: references
        }
        db[:email].where(id: row[:id]).update(updates)
      rescue Mail::Field::NilParseError, ArgumentError => e
        progress.log("enrich parse error id=#{row[:id]}: #{e.class}: #{e.message}")
      rescue => e
        progress.log("enrich error id=#{row[:id]}: #{e.class}: #{e.message}")
      ensure
        progress.increment
      end
      progress.finish
    end
  end
end
