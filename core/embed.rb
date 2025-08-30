#!/usr/bin/env ruby
# frozen_string_literal: true

require "sequel"
require "ruby-progressbar"
require_relative "lib/nittymail/util"
require_relative "lib/nittymail/db"
require_relative "lib/nittymail/embeddings"

module NittyMail
  class Embed
    def self.perform(database_path:, ollama_host:, model: ENV["EMBEDDING_MODEL"] || "mxbai-embed-large", dimension: (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i, item_types: %w[subject body], address_filter: nil, limit: nil, offset: nil, quiet: false, threads_count: 2, retry_attempts: 3, batch_size: 1000)
      raise ArgumentError, "database_path is required" if database_path.to_s.strip.empty?
      raise ArgumentError, "ollama_host is required (set OLLAMA_HOST or pass --ollama-host)" if ollama_host.to_s.strip.empty?

      db = NittyMail::DB.connect(database_path, wal: true, load_vec: true)
      email_ds = NittyMail::DB.ensure_schema!(db)
      NittyMail::DB.ensure_vec_tables!(db, dimension: dimension)

      ds = email_ds
      ds = ds.where(address: address_filter) if address_filter && !address_filter.strip.empty?
      ds = ds.offset(offset.to_i) if offset && offset.to_i > 0
      ds = ds.limit(limit.to_i) if limit && limit.to_i > 0

      total_emails = ds.count
      puts "Embedding #{total_emails} email(s)#{address_filter ? " for #{address_filter}" : ""} using model=#{model} dim=#{dimension} at #{ollama_host}"

      # Phase 1: plan to get an accurate job count without holding all jobs
      plan_progress = ProgressBar.create(title: "plan (emails)", total: total_emails, format: "%t: |%B| %p%% (%c/%C) [%e]")
      total_jobs = 0
      ds.each do |row|
        if item_types.include?("subject")
          subj = row[:subject].to_s
          total_jobs += 1 if !subj.nil? && !subj.empty? && missing_embedding?(db, row[:id], :subject, model)
        end
        if item_types.include?("body")
          raw = row[:encoded]
          mail = NittyMail::Util.parse_mail_safely(raw, mbox_name: row[:mailbox], uid: row[:uid])
          body_text = NittyMail::Util.safe_utf8(mail&.text_part&.decoded || mail&.body&.decoded)
          if body_text.include?("<") && body_text.include?(">") && mail&.text_part.nil? && mail&.html_part
            body_text = body_text.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
          end
          total_jobs += 1 if body_text && !body_text.empty? && missing_embedding?(db, row[:id], :body, model)
        end
      rescue => e
        plan_progress.log "plan error id=#{row[:id]}: #{e.class}: #{e.message}"
      ensure
        plan_progress.increment
      end
      plan_progress.finish

      # Phase 2: stream jobs with bounded queue instead of accumulating all in memory
      progress = ProgressBar.create(title: "embed (jobs)", total: total_jobs, format: "%t: |%B| %p%% (%c/%C) [%e]")
      job_queue = Queue.new
      write_queue = Queue.new

      writer = Thread.new do
        done = 0
        last_log_at = Time.now
        loop do
          job = write_queue.pop
          break if job == :__STOP__
          begin
            NittyMail::DB.upsert_email_embedding!(db, email_id: job[:email_id], vector: job[:vector], item_type: job[:item_type], model: model, dimension: dimension)
            progress.increment
            done += 1
            if !quiet && ((done % 100).zero? || (Time.now - last_log_at) >= 2)
              progress.log("embedded #{done}/#{progress.total} | queues: job=#{job_queue.size} write=#{write_queue.size}")
              last_log_at = Time.now
            end
          rescue => e
            progress.log("db upsert error id=#{job[:email_id]}: #{e.class}: #{e.message}")
          end
        end
      end

      threads = Array.new([threads_count.to_i, 1].max) do
        Thread.new do
          loop do
            job = job_queue.pop
            break if job == :__STOP__
            begin
              vector = fetch_with_retry(ollama_host: ollama_host, model: model, text: job[:text], retry_attempts: retry_attempts)
              write_queue << {email_id: job[:email_id], item_type: job[:item_type], vector: vector} if vector && vector.length == dimension
            rescue => e
              progress.log("embed fetch error id=#{job[:email_id]}: #{e.class}: #{e.message}")
            end
          end
        end
      end

      # Enqueue jobs in a second pass, applying simple backpressure using batch_size
      enqueued = 0
      ds.each do |row|
        if item_types.include?("subject")
          subj = row[:subject].to_s
          if !subj.nil? && !subj.empty? && missing_embedding?(db, row[:id], :subject, model)
            job_queue << {email_id: row[:id], item_type: :subject, text: subj}
            enqueued += 1
          end
        end
        if item_types.include?("body")
          raw = row[:encoded]
          mail = NittyMail::Util.parse_mail_safely(raw, mbox_name: row[:mailbox], uid: row[:uid])
          body_text = NittyMail::Util.safe_utf8(mail&.text_part&.decoded || mail&.body&.decoded)
          if body_text.include?("<") && body_text.include?(">") && mail&.text_part.nil? && mail&.html_part
            body_text = body_text.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
          end
          if body_text && !body_text.empty? && missing_embedding?(db, row[:id], :body, model)
            job_queue << {email_id: row[:id], item_type: :body, text: body_text}
            enqueued += 1
          end
        end
        # apply backpressure if queue grows beyond window
        if batch_size.to_i > 0
          while job_queue.size >= batch_size.to_i
            sleep 0.05
          end
        end
      rescue => e
        progress.log "enqueue error id=#{row[:id]}: #{e.class}: #{e.message}"
      end

      threads_count.to_i.times { job_queue << :__STOP__ }
      threads.each(&:join)
      write_queue << :__STOP__
      writer.join
    end

    def self.missing_embedding?(db, email_id, item_type, model)
      !db[:email_vec_meta].where(email_id: email_id, item_type: item_type.to_s, model: model).first
    end

    def self.fetch_with_retry(ollama_host:, model:, text:, retry_attempts: 3)
      attempts = 0
      loop do
        return NittyMail::Embeddings.fetch_embedding(ollama_host: ollama_host, model: model, text: text)
      rescue OpenSSL::SSL::SSLError, IOError, Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout => e
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
