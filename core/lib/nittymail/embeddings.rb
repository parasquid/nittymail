# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "db"

module NittyMail
  module Embeddings
    module_function

    # Fetch a single embedding vector from an Ollama server
    def fetch_embedding(ollama_host:, model:, text:)
      raise ArgumentError, "ollama_host is required" if ollama_host.nil? || ollama_host.strip.empty?
      uri = URI.parse(File.join(ollama_host, "/api/embeddings"))
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req.body = {model: model, prompt: text.to_s}.to_json
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        raise "ollama embeddings HTTP #{res.code}: #{res.body}"
      end
      data = JSON.parse(res.body)
      emb = data["embedding"] || data["data"]&.first&.fetch("embedding", nil)
      raise "no embedding in response" unless emb.is_a?(Array)
      emb.map(&:to_f)
    end

    # Given a hash of item_type => text, fetch embeddings and store them
    # with the provided email_id.
    def embed_fields_for_email!(db, email_id:, fields:, ollama_host:, model:, dimension: 1024)
      return if fields.nil? || fields.empty?
      fields.each do |item_type, text|
        next if text.nil? || text.strip.empty?
        vector = fetch_embedding(ollama_host: ollama_host, model: model, text: text)
        if vector.length != dimension
          raise "embedding dimension mismatch: got #{vector.length}, expected #{dimension}"
        end
        NittyMail::DB.upsert_email_embedding!(db, email_id: email_id, vector: vector, item_type: item_type.to_s, model: model, dimension: dimension)
      end
    end
  end
end
