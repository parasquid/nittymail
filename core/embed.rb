#!/usr/bin/env ruby
# frozen_string_literal: true

require "sequel"
require "ruby-progressbar"
require_relative "lib/nittymail/util"
require_relative "lib/nittymail/db"
require_relative "lib/nittymail/embeddings"

module NittyMail
  class Embed
    class Settings
      attr_accessor :database_path, :ollama_host, :model, :dimension, :item_types, :address_filter,
        :limit, :offset, :quiet, :threads_count, :retry_attempts, :batch_size

      DEFAULTS = {
        model: ENV["EMBEDDING_MODEL"] || "mxbai-embed-large",
        dimension: (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i,
        item_types: %w[subject body],
        address_filter: nil,
        limit: nil,
        offset: nil,
        quiet: false,
        threads_count: 2,
        retry_attempts: 3,
        batch_size: 1000
      }.freeze

      def initialize(**options)
        required = [:database_path, :ollama_host]
        missing = required - options.keys
        raise ArgumentError, "Missing required options: #{missing.join(", ")}" unless missing.empty?
        DEFAULTS.merge(options).each { |key, value| instance_variable_set("@#{key}", value) }
      end
    end

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

      db = NittyMail::DB.connect(settings.database_path, wal: true, load_vec: true)
      email_ds = NittyMail::DB.ensure_schema!(db)
      NittyMail::DB.ensure_vec_tables!(db, dimension: settings.dimension)

      ds = email_ds
      ds = ds.where(address: settings.address_filter) if settings.address_filter && !settings.address_filter.strip.empty?
      ds = ds.offset(settings.offset.to_i) if settings.offset && settings.offset.to_i > 0
      ds = ds.limit(settings.limit.to_i) if settings.limit && settings.limit.to_i > 0

      total_emails = ds.count
      puts "Checking #{total_emails} email(s)#{settings.address_filter ? " for #{settings.address_filter}" : ""} using model=#{settings.model} dim=#{settings.dimension} at #{settings.ollama_host}"

      # Stream jobs with bounded queue instead of pre-planning entire dataset
      stop_requested = false
      original_int_handler = trap("INT") { stop_requested = true }
      original_term_handler = trap("TERM") { stop_requested = true }
      # Calculate total emails needing embeddings with a simple query
      # Find emails that don't have ANY of the requested embedding types
      total_emails_without_embeddings = ds.where(
        ~ds.db[:email_vec_meta].where(
          email_id: Sequel[:email][:id],
          item_type: settings.item_types.map(&:to_s),
          model: settings.model
        ).exists
      ).count
      
      if total_emails_without_embeddings == 0
        puts "No embedding jobs needed - all emails already have embeddings for requested item types."
        # Clean up database connection on early return
        begin
          db&.disconnect
        rescue => e
          warn "Warning: Database disconnect failed: #{e.class}: #{e.message}"
        end
        return
      end
      
      # Estimate total jobs (emails × item_types that need embeddings)
      estimated_jobs = total_emails_without_embeddings * settings.item_types.length
      puts "Processing #{total_emails_without_embeddings} emails (estimated #{estimated_jobs} embedding jobs)" unless settings.quiet
      progress = ProgressBar.create(title: "embed", total: estimated_jobs, format: "%t: |%B| %p%% (%c/%C) job=? write=? [%e]")
      job_queue = Queue.new
      write_queue = Queue.new
      embedded_done = 0

      writer = Thread.new do
        last_log_at = Time.now
        batch = []
        batch_size = 50  # Process embeddings in batches of 50
        last_flush = Time.now
        
        loop do
          break if stop_requested
          
          # Collect items for batch processing
          begin
            job = write_queue.pop(true) # non-blocking
            if job == :__STOP__
              # Process final batch before stopping
              process_batch(db, batch, progress, embedded_done, settings) unless batch.empty?
              break
            end
            batch << job
          rescue ThreadError # empty queue
            # Process batch if we have items and it's been a while, or if batch is full
            if !batch.empty? && (batch.size >= batch_size || (Time.now - last_flush) >= 1.0)
              embedded_done += process_batch(db, batch, progress, embedded_done, settings)
              batch.clear
              last_flush = Time.now
            else
              sleep 0.1
            end
            next
          end
          
          # Process batch when it's full
          if batch.size >= batch_size
            embedded_done += process_batch(db, batch, progress, embedded_done, settings)
            batch.clear
            last_flush = Time.now
          end
          
          # Update progress bar format periodically
          if (embedded_done % 50).zero? || (Time.now - last_log_at) >= 1
            progress.format = "embed: |%B| %p%% (%c/%C) job=#{job_queue.size} write=#{write_queue.size} [%e]"
            last_log_at = Time.now
          end
        end
      end

      threads = Array.new([settings.threads_count.to_i, 1].max) do
        Thread.new do
          loop do
            break if stop_requested
            begin
              job = job_queue.pop(true) # non-blocking
            rescue ThreadError # empty queue
              sleep 0.1
              next
            end
            break if job == :__STOP__
            begin
              vector = fetch_with_retry(ollama_host: settings.ollama_host, model: settings.model, text: job[:text], retry_attempts: settings.retry_attempts, stop_requested: -> { stop_requested })
              write_queue << {email_id: job[:email_id], item_type: job[:item_type], vector: vector} if vector && vector.length == settings.dimension
            rescue => e
              progress.log("embed fetch error id=#{job[:email_id]}: #{e.class}: #{e.message}")
            end
          end
        end
      end

      # Enqueue jobs; apply simple backpressure using batch_size
      begin
        ds.each do |row|
          break if stop_requested

          if settings.item_types.include?("subject")
            subj = row[:subject].to_s
            if !subj.nil? && !subj.empty? && missing_embedding?(db, row[:id], :subject, settings.model)
              job_queue << {email_id: row[:id], item_type: :subject, text: subj}
            end
          end
          if settings.item_types.include?("body")
            raw = row[:encoded]
            mail = NittyMail::Util.parse_mail_safely(raw, mbox_name: row[:mailbox], uid: row[:uid])
            body_text = NittyMail::Util.safe_utf8(mail&.text_part&.decoded || mail&.body&.decoded)
            if body_text.include?("<") && body_text.include?(">") && mail&.text_part.nil? && mail&.html_part
              body_text = body_text.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
            end
            if body_text && !body_text.empty? && missing_embedding?(db, row[:id], :body, settings.model)
              job_queue << {email_id: row[:id], item_type: :body, text: body_text}
            end
          end
          # apply backpressure if queue grows beyond window
          if settings.batch_size.to_i > 0
            while job_queue.size >= settings.batch_size.to_i
              break if stop_requested
              sleep 0.05
            end
          end
        rescue => e
          progress.log "enqueue error id=#{row[:id]}: #{e.class}: #{e.message}"
        end
      rescue Interrupt
        stop_requested = true
        progress.log("Interrupt received, stopping...")
      ensure
        # Restore original signal handlers
        trap("INT", original_int_handler)
        trap("TERM", original_term_handler)
        
        # Clean up threads
        settings.threads_count.to_i.times { job_queue << :__STOP__ }
        threads.each(&:join)
        write_queue << :__STOP__
        writer.join
        
        # Ensure progress bar finishes cleanly
        begin
          progress&.finish
        rescue => e
          warn "Warning: Progress bar finish failed: #{e.class}: #{e.message}"
        end
        
        if stop_requested
          puts "Interrupted: embedded #{embedded_done}/#{progress.total} jobs processed (job_queue=#{job_queue.size}, write_queue=#{write_queue.size})."
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
          puts "Processing complete. Finalizing database writes (WAL checkpoint)..." unless settings.quiet
        end
      end
    ensure
      # Force WAL checkpoint and disconnect
      begin
        db&.run("PRAGMA wal_checkpoint(TRUNCATE)")
        puts "Database finalization complete." unless settings.quiet
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

    # Process a batch of embeddings in a single transaction for better performance
    def self.process_batch(db, batch, progress, embedded_done, settings)
      return 0 if batch.empty?
      
      processed_count = 0
      
      db.transaction do
        batch.each do |job|
          begin
            NittyMail::DB.upsert_email_embedding!(
              db, 
              email_id: job[:email_id], 
              vector: job[:vector], 
              item_type: job[:item_type], 
              model: settings.model, 
              dimension: settings.dimension
            )
            progress.increment
            processed_count += 1
          rescue => e
            progress.log("db upsert error id=#{job[:email_id]}: #{e.class}: #{e.message}")
          end
        end
      end
      
      processed_count
    end

    def self.missing_embedding?(db, email_id, item_type, model)
      !db[:email_vec_meta].where(email_id: email_id, item_type: item_type.to_s, model: model).first
    end

    def self.fetch_with_retry(ollama_host:, model:, text:, retry_attempts: 3, stop_requested: nil)
      attempts = 0
      loop do
        return nil if stop_requested&.call
        return NittyMail::Embeddings.fetch_embedding(ollama_host: ollama_host, model: model, text: text)
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
