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
