# frozen_string_literal: true

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
