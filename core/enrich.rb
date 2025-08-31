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

      # Add interrupt handling
      stop_requested = false
      trap("INT") { stop_requested = true }
      trap("TERM") { stop_requested = true }

      progress = ProgressBar.create(title: "enrich", total: total, format: "%t: |%B| %p%% (%c/%C) [%e]")
      begin
        ds.each do |row|
          break if stop_requested
        raw = row[:encoded]
        mail = NittyMail::Util.parse_mail_safely(raw, mbox_name: row[:mailbox], uid: row[:uid])

        # Reconstruct envelope with field-specific error handling
        env_to = NittyMail::Util.safe_json(mail&.to, on_error: "enrich to field error id=#{row[:id]}: encoding error")
        
        env_cc = NittyMail::Util.safe_json(mail&.cc, on_error: "enrich cc field error id=#{row[:id]}: encoding error")
        
        env_bcc = NittyMail::Util.safe_json(mail&.bcc, on_error: "enrich bcc field error id=#{row[:id]}: encoding error")
        
        env_reply_to = NittyMail::Util.safe_json(mail&.reply_to, on_error: "enrich reply_to field error id=#{row[:id]}: encoding error")
        
        in_reply_to = begin
          NittyMail::Util.safe_utf8(mail&.in_reply_to)
        rescue => e
          progress.log("enrich in_reply_to field error id=#{row[:id]}: #{e.class}: #{e.message}")
          ""
        end
        
        references = NittyMail::Util.safe_json(mail&.references, on_error: "enrich references field error id=#{row[:id]}: encoding error")

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
        
        # Retry database updates on lock errors
        retries = 3
        begin
          db[:email].where(id: row[:id]).update(updates)
        rescue Sequel::SerializationFailure => e
          retries -= 1
          if retries > 0 && e.message.include?("database is locked")
            sleep(rand(0.1..0.5)) # Random backoff
            retry
          else
            raise e
          end
        end
        
        rescue Mail::Field::NilParseError, ArgumentError => e
          progress.log("enrich parse error id=#{row[:id]}: #{e.class}: #{e.message}")
        rescue => e
          progress.log("enrich error id=#{row[:id]}: #{e.class}: #{e.message}")
        ensure
          progress.increment
        end
      rescue Interrupt
        stop_requested = true
        progress.log("Interrupt received, stopping...")
      ensure
        progress.finish
        if stop_requested
          puts "Interrupted: processed #{progress.progress}/#{progress.total} emails."
        end
      end
    ensure
      db&.disconnect
    end
  end
end
