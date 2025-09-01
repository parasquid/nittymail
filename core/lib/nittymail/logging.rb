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
  module Logging
    module_function

    # Format a concise preview of UIDs slated for syncing
    def format_uids_preview(uids)
      return "uids to be synced: []" if uids.nil? || uids.empty?
      preview_count = [uids.size, 5].min
      preview = uids.first(preview_count).join(", ")
      more = uids.size - preview_count
      suffix = (more > 0) ? ", ... (#{more} more uids)" : ""
      "uids to be synced: [#{preview}#{suffix}]"
    end
  end
end
