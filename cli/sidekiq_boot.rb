# frozen_string_literal: true

require "bundler/setup"
require "active_job"
require "sidekiq"
# Load env vars from .env when available; Docker Compose also injects envs.
begin
  require "dotenv/load"
rescue LoadError
  warn "[sidekiq_boot] dotenv not found; using existing environment variables"
end

# Configure Active Job to use Sidekiq adapter
ActiveJob::Base.queue_adapter = :sidekiq

# Ensure DB is ready for jobs
require_relative "utils/db"
NittyMail::DB.establish_sqlite_connection(database_path: ENV["NITTYMAIL_SQLITE_DB"], address: ENV["NITTYMAIL_IMAP_ADDRESS"]) # address only affects default path
NittyMail::DB.run_migrations!

# Load models so jobs can reference Email, etc.
require_relative "models/email"

# Jobs will be added under ./jobs (to be created in later tasks)
jobs_dir = File.expand_path("jobs", __dir__)
$LOAD_PATH.unshift(jobs_dir) unless $LOAD_PATH.include?(jobs_dir)
