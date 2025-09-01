# frozen_string_literal: true

# Copyright 2025 parasquid

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

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
