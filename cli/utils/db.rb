# frozen_string_literal: true

require "chroma-db"

module NittyMail
  module DB
    module_function

    # Configure Chroma client and return the target collection.
    # - Reads defaults from ENV if not provided.
    # - Ensures connect_host/api_base/api_version are set before accessing collection.
    #
    # Params:
    # - collection_name: String, required
    # - host: optional String; defaults to ENV["NITTYMAIL_CHROMA_HOST"] or http://chroma:8000
    # - api_base: optional String; defaults to ENV["NITTYMAIL_CHROMA_API_BASE"] (nil to leave default)
    # - api_version: optional String; defaults to ENV["NITTYMAIL_CHROMA_API_VERSION"] (nil to leave default)
    def chroma_collection(collection_name, host: nil, api_base: nil, api_version: nil)
      host ||= ENV["NITTYMAIL_CHROMA_HOST"] || "http://chroma:8000"
      api_base = ENV["NITTYMAIL_CHROMA_API_BASE"] if api_base.nil?
      api_version = ENV["NITTYMAIL_CHROMA_API_VERSION"] if api_version.nil?

      Chroma.connect_host = host
      Chroma.api_base = api_base unless api_base.to_s.empty?
      Chroma.api_version = api_version unless api_version.to_s.empty?

      Chroma::Resources::Collection.get_or_create(collection_name)
    end
  end
end

