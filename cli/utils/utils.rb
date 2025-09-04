# frozen_string_literal: true

module NittyMail
  module Utils
    module_function

    # Sanitize string into a valid Chroma collection name:
    # - 3-63 chars, start/end alphanumeric
    # - only [A-Za-z0-9_-]
    # - no consecutive periods (we remove periods entirely)
    def sanitize_collection_name(name)
      s = name.to_s.downcase
      s = s.gsub(/[^a-z0-9_-]+/, "-")  # replace invalid with '-'
      s = s.gsub(/-+/, "-")            # collapse dashes
      s = s.gsub(/^[-_]+|[-_]+$/, "")  # trim non-alnum at ends
      s = "nm" if s.length < 3
      s = s[0, 63]
      # ensure ends with alnum after truncate
      s = s.gsub(/[^a-z0-9]+\z/, "")
      s = "nm" if s.empty?
      s
    end
  end
end

