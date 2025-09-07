#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "thor"
require "json"
require "uri"
require "net/http"
require "nitty_mail"
require "ruby-progressbar"
require_relative "utils/db"
require_relative "utils/utils"
require_relative "models/email"
require_relative "commands/mailbox"
require_relative "commands/db/mcp"

module NittyMail
  class CLI < Thor
    # Removed custom Chroma client in favor of the official gem `chroma-db`.
    # Subcommand: mailbox
    desc "mailbox SUBCOMMAND ...ARGS", "Mailbox commands"
    subcommand "mailbox", NittyMail::Commands::Mailbox

    # Subcommand: db
    desc "db SUBCOMMAND ...ARGS", "Database commands (no IMAP)"
    subcommand "db", NittyMail::Commands::DB
  end
end

if $PROGRAM_NAME == __FILE__
  NittyMail::CLI.start(ARGV)
end
