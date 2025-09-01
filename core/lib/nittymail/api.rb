# frozen_string_literal: true

require_relative "../sync"
require_relative "../embed"
require_relative "../enrich"

module NittyMail
  # Thin convenience wrapper for library consumers
  module API
    module_function

    def sync(settings_or_options)
      NittyMail::Sync.perform(settings_or_options)
    end

    def embed(settings)
      NittyMail::Embed.perform(settings)
    end

    def enrich(**kwargs)
      NittyMail::Enrich.perform(**kwargs)
    end
  end
end
