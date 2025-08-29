#!/usr/bin/env ruby
# frozen_string_literal: true

require "sequel"
require "ruby-progressbar"
require_relative "lib/nittymail/util"
require_relative "lib/nittymail/db"
require_relative "lib/nittymail/embeddings"

module NittyMail
  class Embed
    def self.perform(database_path:, ollama_host:, model: ENV["EMBEDDING_MODEL"] || "mxbai-embed-large", dimension: (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i, item_types: %w[subject body], address_filter: nil, limit: nil, offset: nil, quiet: false, threads_count: 2, retry_attempts: 3)
      raise ArgumentError, "database_path is required" if database_path.to_s.strip.empty?
      raise ArgumentError, "ollama_host is required (set OLLAMA_HOST or pass --ollama-host)" if ollama_host.to_s.strip.empty?

      db = Sequel.sqlite(database_path)
      NittyMail::DB.configure_performance!(db, wal: true)
      email_ds = NittyMail::DB.ensure_schema!(db)
      NittyMail::DB.ensure_vec_tables!(db, dimension: dimension)

      ds = email_ds
      ds = ds.where(address: address_filter) if address_filter && !address_filter.strip.empty?
      ds = ds.offset(offset.to_i) if offset && offset.to_i > 0
      ds = ds.limit(limit.to_i) if limit && limit.to_i > 0

      total = ds.count
      puts "Embedding #{total} email(s)#{address_filter ? " for #{address_filter}" : ""} using model=#{model} dim=#{dimension} at #{ollama_host}"
      progress = ProgressBar.create(title: "embed", total: total, format: "%t: |%B| %p%% (%c/%C) [%e]")

      job_queue = Queue.new
      write_queue = Queue.new

      # Writer thread: serialize DB upserts for vec tables
      writer = Thread.new do
        loop do
          job = write_queue.pop
          break if job == :__STOP__
          begin
            NittyMail::DB.upsert_email_embedding!(db, email_id: job[:email_id], vector: job[:vector], item_type: job[:item_type], model: model, dimension: dimension)
            progress.log("embedded #{job[:item_type]} id=#{job[:email_id]}") unless quiet
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
              if vector && vector.length == dimension
                write_queue << {email_id: job[:email_id], item_type: job[:item_type], vector: vector}
              else
                progress.log("skip id=#{job[:email_id]} #{job[:item_type]} (dimension mismatch)") unless quiet
              end
            rescue => e
              progress.log("embed fetch error id=#{job[:email_id]}: #{e.class}: #{e.message}")
            end
          end
        end
      end

      ds.each do |row|
        enqueued = false
        if item_types.include?("subject")
          subj = row[:subject].to_s
          if !subj.nil? && !subj.empty? && missing_embedding?(db, row[:id], :subject, model)
            job_queue << {email_id: row[:id], item_type: :subject, text: subj}
            enqueued = true
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
            enqueued = true
          end
        end
        unless enqueued
          progress.log("skip id=#{row[:id]} (nothing to embed or already present)") unless quiet
        end
      rescue => e
        progress.log("enqueue error id=#{row[:id]}: #{e.class}: #{e.message}")
      ensure
        progress.increment
      end

      # Signal workers to stop and wait
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
