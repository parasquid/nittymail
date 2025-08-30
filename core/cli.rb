#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright 2023 parasquid

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

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("Gemfile", __dir__)
require "bundler/setup"
require "dotenv/load"
require "thor"
require_relative "sync"
require_relative "embed"
require_relative "query"

# NittyMail CLI application
class NittyMailCLI < Thor
  def self.exit_on_failure?
    true
  end

  desc "sync", "Sync Gmail messages to SQLite database"
  option :address, aliases: "-a", desc: "Gmail address to sync", type: :string
  option :password, aliases: "-p", desc: "Gmail password or app password", type: :string
  option :database, aliases: "-d", desc: "SQLite database file path", type: :string
  option :threads, aliases: "-t", desc: "Number of threads for parallel processing (default: 1)", type: :numeric
  option :mailbox_threads, aliases: "-m", desc: "Threads for mailbox preflight (UID discovery) (default: 1)", type: :numeric
  option :auto_confirm, aliases: "-y", desc: "Skip confirmation prompt", type: :boolean, default: false
  option :purge_old_validity, desc: "Purge rows from older UIDVALIDITY generations after successful sync", type: :boolean, default: false
  option :fetch_batch_size, aliases: "-b", desc: "UID FETCH batch size (default: 100)", type: :numeric
  option :ignore_mailboxes, aliases: "-I", desc: "Comma-separated mailbox names/patterns to ignore (supports * and ?)", type: :string
  option :only, aliases: "-O", desc: "Mailbox names/patterns to include (array; supports * and ?) — others are skipped. Accepts space- or comma-separated values.", type: :array
  option :strict_errors, aliases: "-S", desc: "Raise exceptions instead of swallowing/logging certain recoverable errors", type: :boolean, default: false
  option :retry_attempts, aliases: "-R", desc: "Max IMAP retry attempts per batch (-1 = retry indefinitely, 0 = no retries)", type: :numeric
  option :prune_missing, aliases: "-P", desc: "Delete DB rows for UIDs missing on server (per mailbox/current UIDVALIDITY)", type: :boolean, default: false
  option :quiet, aliases: "-q", desc: "Quiet mode: only show progress bars and high-level operations", type: :boolean, default: false
  option :sqlite_wal, desc: "Enable SQLite WAL journaling for better write performance", type: :boolean, default: true
  def sync
    # Get configuration from CLI options or environment variables
    imap_address = options[:address] || ENV["ADDRESS"]
    imap_password = options[:password] || ENV["PASSWORD"]
    database_path = options[:database] || ENV["DATABASE"]
    threads_count = options[:threads] || (ENV["THREADS"] || "1").to_i
    auto_confirm = options[:auto_confirm] || (ENV["SYNC_AUTO_CONFIRM"] && %w[1 true yes y].include?(ENV["SYNC_AUTO_CONFIRM"].to_s.downcase))
    mailbox_threads = options[:mailbox_threads] || (ENV["MAILBOX_THREADS"] || "1").to_i
    purge_old_validity = options[:purge_old_validity] || (ENV["PURGE_OLD_VALIDITY"] && %w[1 true yes y].include?(ENV["PURGE_OLD_VALIDITY"].to_s.downcase))
    fetch_batch_size = options[:fetch_batch_size] || (ENV["FETCH_BATCH_SIZE"] || "100").to_i
    ignore_mailboxes_raw = options[:ignore_mailboxes] || ENV["MAILBOX_IGNORE"]
    only_opt = options[:only]
    only_env = ENV["ONLY_MAILBOXES"]
    # Support both array input (Thor) and comma-separated strings; split entries on commas and strip
    only_parts = []
    only_parts.concat(Array(only_opt)) if only_opt
    only_parts.concat(Array(only_env)) if only_env
    ignore_mailboxes = (ignore_mailboxes_raw || "").split(",").map { |s| s.strip }.reject(&:empty?)
    only_mailboxes = only_parts.flat_map { |x| x.to_s.split(",") }.map { |s| s.strip }.reject(&:empty?)
    strict_errors = options[:strict_errors] || (ENV["STRICT_ERRORS"] && %w[1 true yes y].include?(ENV["STRICT_ERRORS"].to_s.downcase))
    retry_attempts = (options[:retry_attempts] || (ENV["RETRY_ATTEMPTS"] || "3").to_i).to_i
    prune_missing = options[:prune_missing] || (ENV["PRUNE_MISSING"] && %w[1 true yes y].include?(ENV["PRUNE_MISSING"].to_s.downcase))
    quiet = options[:quiet] || (ENV["QUIET"] && %w[1 true yes y].include?(ENV["QUIET"].to_s.downcase))
    sqlite_wal = if ENV.key?("SQLITE_WAL")
      %w[1 true yes y on].include?(ENV["SQLITE_WAL"].to_s.downcase)
    else
      options[:sqlite_wal]
    end

    # Validate required parameters
    unless imap_address && imap_password && database_path
      puts "Error: Missing required configuration!"
      puts "Please provide:"
      puts "  --address (-a) or ADDRESS env var: Gmail address"
      puts "  --password (-p) or PASSWORD env var: Gmail password/app password"
      puts "  --database (-d) or DATABASE env var: SQLite database file path"
      puts ""
      puts "Example: ./cli.rb sync -a user@gmail.com -p app_password -d data/mail.sqlite3"
      exit 1
    end

    # Ensure threads count is valid
    threads_count = 1 if threads_count < 1
    fetch_batch_size = 1 if fetch_batch_size < 1

    # Confirm account before proceeding
    if auto_confirm
      puts "Starting sync for #{imap_address} (auto-confirmed)"
    elsif $stdin.tty?
      print "This will initiate a sync for #{imap_address}. Continue? [y/N]: "
      answer = $stdin.gets&.strip&.downcase
      unless %w[y yes].include?(answer)
        puts "Aborted by user."
        exit 1
      end
    else
      puts "Starting sync for #{imap_address}"
    end

    # Perform the sync using the library
    NittyMail::Sync.perform(
      imap_address:,
      imap_password:,
      database_path:,
      threads_count:,
      mailbox_threads:,
      purge_old_validity:,
      auto_confirm:,
      fetch_batch_size:,
      ignore_mailboxes:,
      only_mailboxes: only_mailboxes,
      strict_errors:,
      retry_attempts:,
      prune_missing:,
      quiet:,
      sqlite_wal:
    )
  end

  desc "version", "Show version information"
  def version
    puts "NittyMail v1.0.0"
    puts "Gmail to SQLite sync tool"
  end

  desc "embed", "Backfill embeddings for existing emails in the database"
  option :database, aliases: "-d", desc: "SQLite database file path", type: :string
  option :address, aliases: "-a", desc: "Optional filter: only embed rows for this Gmail address", type: :string
  option :item_types, aliases: "-i", desc: "Comma-separated fields to embed (subject,body)", type: :string
  option :limit, aliases: "-n", desc: "Limit number of emails to process", type: :numeric
  option :offset, desc: "Offset for pagination", type: :numeric
  option :ollama_host, desc: "Ollama base URL for embeddings (e.g., http://localhost:11434)", type: :string
  option :model, desc: "Embedding model name (defaults to EMBEDDING_MODEL or mxbai-embed-large)", type: :string
  option :dimension, desc: "Embedding dimension (defaults to SQLITE_VEC_DIMENSION or 1024)", type: :numeric
  option :threads, aliases: "-t", desc: "Number of embedding worker threads (default from THREADS or 2)", type: :numeric
  option :retry_attempts, aliases: "-R", desc: "Max embedding retry attempts (-1 = retry indefinitely, 0 = no retries)", type: :numeric
  option :quiet, aliases: "-q", desc: "Reduce log output", type: :boolean, default: false
  option :batch_size, aliases: "-b", desc: "Emails-to-queue window during embed (default: 1000)", type: :numeric
  def embed
    database_path = options[:database] || ENV["DATABASE"]
    ollama_host = options[:ollama_host] || ENV["OLLAMA_HOST"]
    model = options[:model] || ENV["EMBEDDING_MODEL"] || "mxbai-embed-large"
    dimension = (options[:dimension] || (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i).to_i
    item_types = (options[:item_types] || "subject,body").split(",").map { |s| s.strip.downcase }.uniq & %w[subject body]
    item_types = %w[subject body] if item_types.empty?
    address_filter = options[:address] || ENV["ADDRESS"]
    limit = options[:limit]&.to_i
    offset = options[:offset]&.to_i
    quiet = options[:quiet]
    threads_count = (options[:threads] || (ENV["THREADS"] || "2").to_i).to_i
    retry_attempts = (options[:retry_attempts] || (ENV["RETRY_ATTEMPTS"] || "3").to_i).to_i
    batch_size = (options[:batch_size] || (ENV["EMBED_BATCH_SIZE"] || "1000").to_i).to_i

    NittyMail::Embed.perform(
      database_path: database_path,
      ollama_host: ollama_host,
      model: model,
      dimension: dimension,
      item_types: item_types,
      address_filter: address_filter,
      limit: limit,
      offset: offset,
      quiet: quiet,
      threads_count: threads_count,
      retry_attempts: retry_attempts,
      batch_size: batch_size
    )
  end

  desc "query PROMPT", "Ask questions against your mail using an LLM with DB tools"
  option :database, aliases: "-d", desc: "SQLite database file path (defaults to DATABASE)", type: :string
  option :address, aliases: "-a", desc: "Gmail address context (defaults to ADDRESS)", type: :string
  option :ollama_host, desc: "Ollama base URL for chat (e.g., http://localhost:11434)", type: :string
  option :model, desc: "Chat model name (default: qwen2.5:7b-instruct)", type: :string
  option :limit, aliases: "-n", desc: "Default result limit when unspecified (default: 100)", type: :numeric
  option :quiet, aliases: "-q", desc: "Reduce log output", type: :boolean, default: false
  option :debug, desc: "Enable debug logging (shows Ollama requests/responses)", type: :boolean, default: false
  def query(prompt = nil)
    prompt ||= ARGV.last if prompt.nil? || prompt.strip.empty?
    if prompt.nil? || prompt.strip.empty?
      puts "Error: query requires a PROMPT argument"
      puts "Example: ./cli.rb query 'show me 5 earliest emails'"
      exit 1
    end

    database_path = options[:database] || ENV["DATABASE"]
    address = options[:address] || ENV["ADDRESS"]
    ollama_host = options[:ollama_host] || ENV["OLLAMA_HOST"]
    model = options[:model] || ENV["QUERY_MODEL"] || "qwen2.5:7b-instruct"
    default_limit = (options[:limit] || 100).to_i
    quiet = options[:quiet]
    debug = options[:debug]

    unless database_path
      puts "Error: DATABASE must be provided via --database or env"
      exit 1
    end

    response = NittyMail::Query.perform(
      database_path: database_path,
      address: address,
      ollama_host: ollama_host,
      model: model,
      prompt: prompt,
      default_limit: default_limit,
      quiet: quiet,
      debug: debug
    )
    puts response
  end
end

# Run the CLI if this file is executed directly
if __FILE__ == $0
  NittyMailCLI.start(ARGV)
end
