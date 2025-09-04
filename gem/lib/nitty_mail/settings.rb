# frozen_string_literal: true

module NittyMail
  class Settings
    attr_reader :imap_url,
      :imap_port,
      :imap_ssl,
      :imap_address,
      :imap_password,
      :max_fetch_size,
      :fetch_items

    DEFAULTS = {
      imap_url: "imap.gmail.com",
      imap_port: 993,
      imap_ssl: true,
      max_fetch_size: 1000,
      fetch_items: [
        "UID",
        "BODY.PEEK[]",
        "BODYSTRUCTURE",
        "ENVELOPE",
        "INTERNALDATE",
        "RFC822.SIZE",
        "FLAGS",
        "X-GM-LABELS",
        "X-GM-MSGID",
        "X-GM-THRID",
      ]
    }.freeze

    REQUIRED = [
      :imap_address,
      :imap_password
    ].freeze

    def initialize(**options)
      validate_required_options!(options)
      merged_options = self.class::DEFAULTS.merge(options)
      merged_options.each { |key, value| instance_variable_set("@#{key}", value) }
    end

    protected

    def validate_required_options!(options)
      required = self.class.const_defined?(:REQUIRED) ? self.class::REQUIRED : []
      missing = required - options.keys
      raise ArgumentError, "Missing required options: #{missing.join(", ")}" unless missing.empty?

      required.each do |key|
        raise ArgumentError, "Required option is nil: #{key}" if options[key].nil?
      end
    end
  end
end
