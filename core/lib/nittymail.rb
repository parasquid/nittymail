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

# NittyMail public library entrypoint
#
# Require this file from external applications to use NittyMail programmatically.
# It exposes the primary modules and convenience API methods to run sync, embed,
# and enrich outside the CLI.

require_relative "nittymail/db"
require_relative "nittymail/util"
require_relative "nittymail/embeddings"
require_relative "nittymail/settings"

# High-level operations and CLI entrypoints
require_relative "nittymail/api"
require_relative "../query"
