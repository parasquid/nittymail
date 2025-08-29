#!/usr/bin/env ruby
# frozen_string_literal: true

require "sequel"
require "ruby-progressbar"
require_relative "lib/nittymail/util"
require_relative "lib/nittymail/db"
require_relative "lib/nittymail/embeddings"

module NittyMail
  class Embed
    def self.perform(database_path:, ollama_host:, model: ENV["EMBEDDING_MODEL"] || "mxbai-embed-large", dimension: (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i, item_types: %w[subject body], address_filter: nil, limit: nil, offset: nil, quiet: false)
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

      ds.each do |row|
        fields = {}
        if item_types.include?("subject")
          subj = row[:subject].to_s
          fields[:subject] = subj if !subj.nil? && !subj.empty? && missing_embedding?(db, row[:id], :subject, model)
        end
        if item_types.include?("body")
          raw = row[:encoded]
          mail = NittyMail::Util.parse_mail_safely(raw, mbox_name: row[:mailbox], uid: row[:uid])
          body_text = NittyMail::Util.safe_utf8(mail&.text_part&.decoded || mail&.body&.decoded)
          if body_text.include?("<") && body_text.include?(">") && mail&.text_part.nil? && mail&.html_part
            body_text = body_text.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
          end
          if body_text && !body_text.empty? && missing_embedding?(db, row[:id], :body, model)
            fields[:body] = body_text
          end
        end
        if fields.any?
          NittyMail::Embeddings.embed_fields_for_email!(db, email_id: row[:id], fields: fields, ollama_host: ollama_host, model: model, dimension: dimension)
          progress.log("embedded email id=#{row[:id]} types=#{fields.keys.join(",")}") unless quiet
        else
          progress.log("skip id=#{row[:id]} (nothing to embed or already present)") unless quiet
        end
        rescue => e
          progress.log("error embedding id=#{row[:id]}: #{e.class}: #{e.message}")
        ensure
          progress.increment
      end
    end

    def self.missing_embedding?(db, email_id, item_type, model)
      !db[:email_vec_meta].where(email_id: email_id, item_type: item_type.to_s, model: model).first
    end
  end
end
