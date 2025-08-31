# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "db"

module NittyMail
  module Embeddings
    module_function

    # Fetch a single embedding vector from an Ollama server
    #
    # Parameters:
    #   - ollama_host: Base URL of Ollama server
    #   - model: Embedding model name
    #   - text: Text to embed
    #   - use_search_prompt: If true, prepends mxbai search optimization prompt for query embeddings
    def fetch_embedding(ollama_host:, model:, text:, use_search_prompt: false)
      raise ArgumentError, "ollama_host is required" if ollama_host.nil? || ollama_host.strip.empty?
      base = URI.parse(ollama_host.strip)
      unless base.is_a?(URI::HTTP) && base.host
        raise ArgumentError, "ollama_host must start with http:// or https:// and include a host (e.g., http://localhost:11434)"
      end

      # Apply mxbai-embed-large optimization prompt for search queries
      prompt_text = if use_search_prompt && model.include?("mxbai")
        "Represent this sentence for searching relevant passages: #{text}"
      else
        text.to_s
      end

      uri = URI.join(base.to_s, "/api/embeddings")
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req.body = {model: model, prompt: prompt_text}.to_json
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
        # signal one field embedded to any callers that track counts
        yield(item_type) if block_given?
      end
    end
  end
end
