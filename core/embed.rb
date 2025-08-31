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
      puts "Embedding #{total_emails} email(s)#{settings.address_filter ? " for #{settings.address_filter}" : ""} using model=#{settings.model} dim=#{settings.dimension} at #{settings.ollama_host}"

      # Stream jobs with bounded queue instead of pre-planning entire dataset
      stop_requested = false
      original_int_handler = trap("INT") { stop_requested = true }
      original_term_handler = trap("TERM") { stop_requested = true }
      progress = ProgressBar.create(title: "embed (jobs)", total: 1, format: "%t: |%B| %p%% (%c/%C) [%e]")
      job_queue = Queue.new
      write_queue = Queue.new
      embedded_done = 0

      writer = Thread.new do
        last_log_at = Time.now
        loop do
          break if stop_requested
          begin
            job = write_queue.pop(true) # non-blocking
          rescue ThreadError # empty queue
            sleep 0.1
            next
          end
          break if job == :__STOP__
          begin
            NittyMail::DB.upsert_email_embedding!(db, email_id: job[:email_id], vector: job[:vector], item_type: job[:item_type], model: settings.model, dimension: settings.dimension)
            progress.increment
            embedded_done += 1
            if !settings.quiet && ((embedded_done % 100).zero? || (Time.now - last_log_at) >= 2)
              progress.log("embedded #{embedded_done}/#{progress.total} | queues: job=#{job_queue.size} write=#{write_queue.size}")
              last_log_at = Time.now
            end
          rescue => e
            progress.log("db upsert error id=#{job[:email_id]}: #{e.class}: #{e.message}")
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

      # Enqueue jobs while workers run; apply simple backpressure using batch_size
      total_jobs = 0
      begin
        ds.each do |row|
          break if stop_requested

          if settings.item_types.include?("subject")
            subj = row[:subject].to_s
            if !subj.nil? && !subj.empty? && missing_embedding?(db, row[:id], :subject, settings.model)
              job_queue << {email_id: row[:id], item_type: :subject, text: subj}
              total_jobs += 1
              progress.total = [total_jobs, 1].max
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
              total_jobs += 1
              progress.total = [total_jobs, 1].max
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
