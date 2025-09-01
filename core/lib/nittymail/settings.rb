# frozen_string_literal: true

module NittyMail
  class BaseSettings
    attr_accessor :database_path, :quiet, :threads_count, :retry_attempts, :reporter, :on_progress

    BASE_DEFAULTS = {
      quiet: false,
      threads_count: 2,
      retry_attempts: 3,
      reporter: nil,
      on_progress: nil
    }.freeze

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
    end
  end
end
