#!/usr/bin/env ruby
# frozen_string_literal: true

require "sequel"
require_relative "lib/nittymail/util"
require_relative "lib/nittymail/db"
require_relative "lib/nittymail/reporter"

module NittyMail
  class Enrich
    def self.perform(database_path:, address_filter: nil, limit: nil, offset: nil, quiet: false, regenerate: false, reporter: nil, on_progress: nil)
      raise ArgumentError, "database_path is required" if database_path.to_s.strip.empty?

      db = NittyMail::DB.connect(database_path, wal: true, load_vec: false)
      email_ds = NittyMail::DB.ensure_schema!(db)
      NittyMail::DB.ensure_enrichment_columns!(db)
      NittyMail::DB.ensure_enrich_indexes!(db)

      # Build reporter (default to no-op for library usage)
      reporter ||= NittyMail::Reporting::NullReporter.new(quiet: quiet, on_progress: on_progress)

      ds = email_ds
      ds = ds.where(address: address_filter) if address_filter && !address_filter.to_s.strip.empty?

      # By default, only process rows that have not yet been enriched.
      # Use rfc822_size as a sentinel column that enrich always sets.
      unless regenerate
        ds = ds.where(rfc822_size: nil)
        reporter.event(:enrich_skipping_enriched, {note: "use --regenerate to reprocess all"})
      end

      ds = ds.offset(offset.to_i) if offset && offset.to_i > 0
      ds = ds.limit(limit.to_i) if limit && limit.to_i > 0

      total = ds.count
      reporter.event(:enrich_started, {total: total, address: address_filter})

      # Add interrupt handling
      stop_requested = false
      original_int_handler = trap("INT") { stop_requested = true }
      original_term_handler = trap("TERM") { stop_requested = true }

      processed = 0
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
            reporter.event(:enrich_field_error, {id: row[:id], field: :in_reply_to, error: e.class.name, message: e.message})
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
          reporter.event(:enrich_error, {id: row[:id], error: e.class.name, message: e.message})
        rescue => e
          reporter.event(:enrich_error, {id: row[:id], error: e.class.name, message: e.message})
        end
        processed += 1
        reporter.event(:enrich_progress, {current: processed, total: total, delta: 1})
      rescue Interrupt
        stop_requested = true
        reporter.event(:enrich_interrupted, {processed: processed, total: total})
      ensure
        # Restore original signal handlers
        trap("INT", original_int_handler)
        trap("TERM", original_term_handler)

        reporter.event(:enrich_finished, {processed: processed, total: total}) unless stop_requested
      end
    ensure
      # Force WAL checkpoint and disconnect
      begin
        db&.run("PRAGMA wal_checkpoint(TRUNCATE)")
        reporter.event(:db_checkpoint_complete, {mode: "TRUNCATE"})
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
