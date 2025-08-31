#!/usr/bin/env ruby
# frozen_string_literal: true

require "sequel"
require "ruby-progressbar"
require_relative "lib/nittymail/util"
require_relative "lib/nittymail/db"

module NittyMail
  class Enrich
    def self.perform(database_path:, address_filter: nil, limit: nil, offset: nil, quiet: false, regenerate: false)
      raise ArgumentError, "database_path is required" if database_path.to_s.strip.empty?

      db = NittyMail::DB.connect(database_path, wal: true, load_vec: false)
      email_ds = NittyMail::DB.ensure_schema!(db)
      NittyMail::DB.ensure_enrichment_columns!(db)

      ds = email_ds
      ds = ds.where(address: address_filter) if address_filter && !address_filter.to_s.strip.empty?

      # By default, only process rows that have not yet been enriched.
      # Use rfc822_size as a sentinel column that enrich always sets.
      unless regenerate
        ds = ds.where(rfc822_size: nil)
        puts "Skipping already-enriched rows (use --regenerate to reprocess all)" unless quiet
      end

      ds = ds.offset(offset.to_i) if offset && offset.to_i > 0
      ds = ds.limit(limit.to_i) if limit && limit.to_i > 0

      total = ds.count
      puts "Enriching #{total} email(s)#{address_filter ? " for #{address_filter}" : ""} from stored raw messages" unless quiet

      # Add interrupt handling
      stop_requested = false
      original_int_handler = trap("INT") { stop_requested = true }
      original_term_handler = trap("TERM") { stop_requested = true }

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
            rfc822_size:,
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
        end
        progress.increment
      rescue Interrupt
        stop_requested = true
        progress.log("Interrupt received, stopping...")
      ensure
        # Restore original signal handlers
        trap("INT", original_int_handler)
        trap("TERM", original_term_handler)

        # Ensure progress bar finishes cleanly
        begin
          progress&.finish
        rescue => e
          warn "Warning: Progress bar finish failed: #{e.class}: #{e.message}"
        end

        if stop_requested
          puts "Interrupted: processed #{progress.progress}/#{progress.total} emails."
        else
          puts "Processing complete. Finalizing database writes (WAL checkpoint)..." unless quiet
        end
      end
    ensure
      # Force WAL checkpoint and disconnect
      begin
        db&.run("PRAGMA wal_checkpoint(TRUNCATE)")
        puts "Database finalization complete." unless quiet
      rescue => e
        warn "Warning: WAL checkpoint failed: #{e.class}: #{e.message}"
      ensure
        begin
          db&.disconnect
        rescue => e
          warn "Warning: Database disconnect failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
