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

require "sequel"
require "ruby-progressbar"
require_relative "lib/nittymail/util"
require_relative "lib/nittymail/db"
require_relative "lib/nittymail/embeddings"
require_relative "lib/nittymail/settings"
require_relative "lib/nittymail/reporter"

module EmbedSettings
  class Settings < NittyMail::BaseSettings
    attr_accessor :ollama_host, :model, :dimension, :item_types, :address_filter,
      :limit, :offset, :batch_size, :regenerate, :use_search_prompt, :write_batch_size,
      :reporter, :on_progress

    REQUIRED = [:database_path, :ollama_host].freeze

    DEFAULTS = BASE_DEFAULTS.merge({
      model: ENV["EMBEDDING_MODEL"] || "bge-m3",
      dimension: (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i,
      item_types: %w[subject body],
      address_filter: nil,
      limit: nil,
      offset: nil,
      batch_size: 1000,
      write_batch_size: (ENV["EMBED_WRITE_BATCH_SIZE"] || "200").to_i,
      regenerate: false,
      use_search_prompt: true,
      reporter: nil,
      on_progress: nil
    }).freeze
  end
end

module NittyMail
  class Embed
    def self.perform(settings)
      raise ArgumentError, "database_path is required" if settings.database_path.to_s.strip.empty?
      raise ArgumentError, "ollama_host is required (set OLLAMA_HOST or pass --ollama-host)" if settings.ollama_host.to_s.strip.empty?
      # Validate Ollama host is a proper HTTP(S) URL early for clearer errors
      begin
        u = URI.parse(settings.ollama_host.to_s.strip)
        unless u.is_a?(URI::HTTP) && u.host
          raise ArgumentError, "ollama_host must start with http:// or https:// and include a host (e.g., http://localhost:11434)"
        end
      rescue URI::InvalidURIError
        raise ArgumentError, "ollama_host is not a valid URL (e.g., http://localhost:11434)"
      end

      reporter = settings.reporter || NittyMail::Reporting::NullReporter.new(quiet: settings.quiet, on_progress: settings.on_progress)

      # Upfront check: ensure the requested model is available on Ollama
      unless NittyMail::Embeddings.model_available?(ollama_host: settings.ollama_host, model: settings.model)
        reporter.event(:embed_error, {error: "ModelUnavailable", message: "Embedding model '#{settings.model}' not found at #{settings.ollama_host}", fatal: true})
        puts "Embedding model '#{settings.model}' not found at #{settings.ollama_host}."
        puts "Hint: pull it with: ollama pull #{settings.model} (or set EMBEDDING_MODEL/--model)."
        return
      end

      db = NittyMail::DB.connect(settings.database_path, wal: true, load_vec: true)
      email_ds = NittyMail::DB.ensure_schema!(db)
      # Ensure helpful general indexes (address/date, etc.) exist on existing DBs
      NittyMail::DB.ensure_query_indexes!(db)

      # Handle regenerate option by dropping existing vector data for this model
      if settings.regenerate
        puts "Regenerating embeddings: deleting existing vector data for model '#{settings.model}'..."
        db.transaction do
          # Delete vector metadata for this model
          deleted_meta = db[:email_vec_meta].where(model: settings.model).delete
          puts "Deleted #{deleted_meta} existing embedding metadata records"

          # Drop and recreate vector tables to clear all vector data
          # This is more efficient than trying to delete specific vectors
          begin
            db.drop_table?(:email_vec)
            puts "Dropped email_vec table"
          rescue => e
            puts "Warning: Failed to drop email_vec table: #{e.message}"
          end
        end

        # Recreate the vector tables after dropping
        puts "Recreating vector tables..."
        NittyMail::DB.ensure_vec_tables!(db, dimension: settings.dimension)
        puts "Vector tables recreated successfully"
      else
        # Normal case: just ensure tables exist
        NittyMail::DB.ensure_vec_tables!(db, dimension: settings.dimension)
      end

      ds = email_ds
      ds = ds.where(address: settings.address_filter) if settings.address_filter && !settings.address_filter.strip.empty?
      ds = ds.offset(settings.offset.to_i) if settings.offset && settings.offset.to_i > 0
      ds = ds.limit(settings.limit.to_i) if settings.limit && settings.limit.to_i > 0

      total_emails = ds.count
      reporter.event(:embed_scan_started, {total_emails:, address: settings.address_filter, model: settings.model, dimension: settings.dimension, host: settings.ollama_host})

      # Stream jobs with bounded queue instead of pre-planning entire dataset
      stop_requested = false
      original_int_handler = trap("INT") { stop_requested = true }
      original_term_handler = trap("TERM") { stop_requested = true }
      # Calculate total emails needing embeddings
      if settings.regenerate
        # When regenerating, process all emails since we cleared existing embeddings
        total_emails_without_embeddings = total_emails
        reporter.event(:embed_regenerate, {total_emails: total_emails})
      else
        # Find emails that don't have ANY of the requested embedding types
        total_emails_without_embeddings = ds.where(
          ~ds.db[:email_vec_meta].where(
            email_id: Sequel[:email][:id],
            item_type: settings.item_types.map(&:to_s),
            model: settings.model
          ).exists
        ).count

        if total_emails_without_embeddings == 0
          reporter.event(:embed_skipped, {reason: :already_embedded})
          # Clean up database connection on early return
          begin
            db&.disconnect
          rescue => e
            warn "Warning: Database disconnect failed: #{e.class}: #{e.message}"
          end
          return
        end
      end

      # Continuous processing: persistent workers with streaming job queue
      estimated_total_jobs = total_emails_without_embeddings * settings.item_types.length
      reporter.event(:embed_started, {estimated_jobs: estimated_total_jobs})

      # Global queues for continuous processing
      job_queue = Queue.new
      write_queue = Queue.new
      embedded_done = 0
      embedded_errors = 0
      last_progress_update = Time.now

      # Start persistent writer thread
      writer = Thread.new do
        reporter.event(:embed_writer_started, {thread: Thread.current.object_id})
        batch = []
        batch_size = [settings.write_batch_size.to_i, 1].max
        last_flush = Time.now

        until stop_requested
          begin
            job = write_queue.pop(true) # non-blocking
            break if job == :__STOP__
            batch << job
          rescue ThreadError # empty queue
            if !batch.empty? && (batch.size >= batch_size || (Time.now - last_flush) >= 1.0)
              processed, db_errors = process_write_batch(db, batch, reporter, settings)
              embedded_errors += db_errors
              reporter.event(:embed_batch_written, {count: processed})
              embedded_done += processed
              batch.clear
              last_flush = Time.now
            else
              sleep 0.1
            end
            next
          end

          if batch.size >= batch_size
            processed, db_errors = process_write_batch(db, batch, reporter, settings)
            embedded_errors += db_errors
            reporter.event(:embed_batch_written, {count: processed})
            embedded_done += processed
            batch.clear
            last_flush = Time.now
          end

          # Update progress bar format with queue sizes periodically
          if (Time.now - last_progress_update) >= 1.0
            reporter.event(:embed_status, {job_queue: job_queue.size, write_queue: write_queue.size})
            reporter.event(:embed_status, {job_queue: job_queue.size, write_queue: write_queue.size})
            last_progress_update = Time.now
          end
        end

        # Process final batch
        unless batch.empty?
          processed, db_errors = process_write_batch(db, batch, reporter, settings)
          embedded_errors += db_errors
          reporter.event(:embed_batch_written, {count: processed})
          embedded_done += processed
        end
        reporter.event(:embed_writer_stopped, {thread: Thread.current.object_id})
      end

      # Start persistent worker threads
      threads = Array.new([settings.threads_count.to_i, 1].max) do
        Thread.new do
          reporter.event(:embed_worker_started, {thread: Thread.current.object_id})
          until stop_requested
            begin
              job = job_queue.pop(true) # non-blocking
            rescue ThreadError # empty queue
              sleep 0.1
              next
            end
            break if job == :__STOP__
            begin
              # Use search prompt optimization based on settings (enabled by default)
              vector = fetch_with_retry(
                ollama_host: settings.ollama_host,
                model: settings.model,
                text: job[:text],
                retry_attempts: settings.retry_attempts,
                stop_requested: -> { stop_requested },
                use_search_prompt: settings.use_search_prompt
              )
              write_queue << {email_id: job[:email_id], item_type: job[:item_type], vector: vector} if vector && vector.length == settings.dimension
            rescue => e
              msg = e.message.to_s
              fatal_model_missing = (msg =~ /ollama embeddings HTTP 404/i) || (msg =~ /model\s+\"?.+\"?\s+not\s+found/i)
              if fatal_model_missing
                reporter.event(:embed_error, {email_id: job[:email_id], error: e.class.name, message: e.message, fatal: true})
                warn "Embedding model '#{settings.model}' not found at #{settings.ollama_host}. Aborting embed."
                warn "Hint: pull it with: ollama pull #{settings.model} (or set EMBEDDING_MODEL/--model)."
                stop_requested = true
                break
              else
                reporter.event(:embed_error, {email_id: job[:email_id], error: e.class.name, message: e.message})
                embedded_errors += 1
              end
            end
          end
          reporter.event(:embed_worker_stopped, {thread: Thread.current.object_id})
        end
      end

      # Stream emails and queue jobs continuously
      batch_size_lookup = 5000
      begin
        ds.each_slice(batch_size_lookup) do |email_batch|
          break if stop_requested

          # Build bulk lookup for this batch of emails (skip if regenerating)
          existing_embeddings = if settings.regenerate
            {} # Empty hash - no existing embeddings to check
          else
            batch_ids = email_batch.map { |row| row[:id] }
            rows = db[:email_vec_meta]
              .where(model: settings.model, item_type: settings.item_types.map(&:to_s), email_id: batch_ids)
              .select(:email_id, :item_type, :vec_rowid)
              .all
            # Map to { email_id => { 'subject' => vec_rowid, 'body' => vec_rowid } }
            h = Hash.new { |hh, k| hh[k] = {} }
            rows.each do |r|
              h[r[:email_id]][r[:item_type]] = r[:vec_rowid]
            end
            h
          end

          # Queue jobs for this batch (workers process immediately)
          enqueued = 0
          email_batch.each do |row|
            break if stop_requested
            email_id = row[:id]
            existing_for_email = existing_embeddings[email_id] || {}

            if settings.item_types.include?("subject")
              subj = row[:subject].to_s
              if !subj.nil? && !subj.empty? && (settings.regenerate || !existing_for_email.key?("subject"))
                job_queue << {email_id: email_id, item_type: :subject, text: subj, vec_rowid: existing_for_email["subject"]}
                enqueued += 1
              end
            end
            if settings.item_types.include?("body")
              if settings.regenerate || !existing_for_email.key?("body")
                body_text = row[:plain_text].to_s
                if body_text.nil? || body_text.strip.empty?
                  raw = row[:encoded]
                  mail = NittyMail::Util.parse_mail_safely(raw, mbox_name: row[:mailbox], uid: row[:uid])
                  body_text = NittyMail::Util.extract_plain_text(mail)
                end
                if body_text && !body_text.empty?
                  job_queue << {email_id: email_id, item_type: :body, text: body_text, vec_rowid: existing_for_email["body"]}
                  enqueued += 1
                end
              end
            end

            # Apply backpressure if job queue gets too large
            if settings.batch_size.to_i > 0
              while job_queue.size >= settings.batch_size.to_i
                break if stop_requested
                sleep 0.05
              end
            end
          end
          reporter.event(:embed_jobs_enqueued, {count: enqueued}) if enqueued > 0
        end

        # Wait for all jobs to complete
        reporter.event(:embed_waiting_for_completion, {job_queue: job_queue.size, write_queue: write_queue.size})
        sleep 0.5 while !stop_requested && (job_queue.size > 0 || write_queue.size > 0)
      rescue Interrupt
        stop_requested = true
        reporter.event(:embed_interrupted_log, {message: "Interrupt received, stopping..."})
      ensure
        # Clean shutdown of persistent threads
        settings.threads_count.to_i.times { job_queue << :__STOP__ }
        write_queue << :__STOP__

        # Wait for threads or kill them if interrupted
        threads.each do |thread|
          if stop_requested
            thread.kill if thread.alive?
          else
            thread.join
          end
        end

        if stop_requested
          writer.kill if writer.alive?
        else
          writer.join
        end

        # no-op for event reporters
        # Restore original signal handlers
        trap("INT", original_int_handler)
        trap("TERM", original_term_handler)

        # Clean up threads
        settings.threads_count.to_i.times { job_queue << :__STOP__ }
        threads.each(&:join)
        write_queue << :__STOP__
        writer.join

        # Ensure progress bar finishes cleanly
        # no-op for event reporters

        if stop_requested
          reporter.event(:embed_interrupted, {processed: embedded_done, total: estimated_total_jobs, errors: embedded_errors, job_queue: job_queue.size, write_queue: write_queue.size})
          # Check if there's significant WAL data to drain
          begin
            wal_info = db.fetch("PRAGMA wal_checkpoint").first
            if wal_info && wal_info[:pages_walted] && wal_info[:pages_walted] > 100
              puts "Draining write-ahead log (#{wal_info[:pages_walted]} pages)..."
            end
          rescue => e
            # Fallback: check if WAL file exists and is substantial
            wal_path = "#{settings.database_path}-wal"
            if File.exist?(wal_path) && File.size(wal_path) > 1_000_000  # > 1MB
              puts "Draining write-ahead log..."
            end
          end
        else
          reporter.event(:embed_finished, {processed: embedded_done, total: estimated_total_jobs, errors: embedded_errors})
        end
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

    # Process a batch of embeddings in a single transaction using prepared statements
    def self.process_write_batch(db, batch, reporter, settings)
      return [0, 0] if batch.empty?

      processed_count = 0
      error_count = 0

      # Ensure vec tables exist once per run; no per-row checks
      NittyMail::DB.ensure_vec_tables!(db, dimension: settings.dimension)

      db.transaction do
        db.synchronize do |conn|
          begin
            insert_vec_stmt = conn.prepare("INSERT INTO email_vec(embedding) VALUES (?)")
            update_vec_stmt = conn.prepare("UPDATE email_vec SET embedding = ? WHERE rowid = ?")
            insert_meta_stmt = conn.prepare("INSERT OR IGNORE INTO email_vec_meta(vec_rowid, email_id, item_type, model, dimension) VALUES (?, ?, ?, ?, ?)")
          rescue => e
            reporter.event(:embed_db_error, {context: "prepare", error: e.class.name, message: e.message})
            error_count += 1
          end

          batch.each do |job|
            packed = job[:vector].pack("f*")
            if job[:vec_rowid]
              update_vec_stmt.execute(SQLite3::Blob.new(packed), job[:vec_rowid])
            else
              conn.execute("INSERT INTO email_vec(embedding) VALUES (?)", SQLite3::Blob.new(packed))
              new_rowid = conn.last_insert_row_id
              insert_meta_stmt.execute(new_rowid, job[:email_id], job[:item_type].to_s, settings.model, settings.dimension)
            end
            processed_count += 1
          rescue => e
            reporter.event(:embed_db_error, {email_id: job[:email_id], error: e.class.name, message: e.message})
            reporter.event(:embed_db_error, {email_id: job[:email_id], error: e.class.name, message: e.message})
            error_count += 1
          end

          begin
            insert_vec_stmt&.close
            update_vec_stmt&.close
            insert_meta_stmt&.close
          rescue => e
            reporter.event(:embed_db_error, {context: "finalize", error: e.class.name, message: e.message})
            error_count += 1
          end
        end
      end

      [processed_count, error_count]
    end

    def self.missing_embedding?(db, email_id, item_type, model)
      !db[:email_vec_meta].where(email_id: email_id, item_type: item_type.to_s, model: model).first
    end

    def self.fetch_with_retry(ollama_host:, model:, text:, retry_attempts: 3, stop_requested: nil, use_search_prompt: false)
      attempts = 0
      loop do
        return nil if stop_requested&.call
        return NittyMail::Embeddings.fetch_embedding(
          ollama_host: ollama_host,
          model: model,
          text: text,
          use_search_prompt: use_search_prompt
        )
      rescue OpenSSL::SSL::SSLError, IOError, Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout => e
        return nil if stop_requested&.call
        attempts += 1
        raise e if retry_attempts == 0
        if retry_attempts > 0 && attempts > retry_attempts
          raise e
        end
        sleep [attempts, 5].min
        next
      end
    end
  end
end
