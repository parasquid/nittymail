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
db_path_effective = ENV["NITTYMAIL_SQLITE_DB"]
addr_hint = ENV["NITTYMAIL_IMAP_ADDRESS"]
NittyMail::DB.establish_sqlite_connection(database_path: db_path_effective, address: addr_hint) # address only affects default path
begin
  resolved = ActiveRecord::Base.connection_db_config&.database || NittyMail::DB.default_database_path(address: addr_hint)
  warn "[sidekiq_boot] ActiveRecord connected to: #{resolved} (address hint=#{addr_hint})"
rescue
end
NittyMail::DB.run_migrations!

# Load models so jobs can reference Email, etc.
require_relative "models/email"

# Jobs will be added under ./jobs (to be created in later tasks)
jobs_dir = File.expand_path("jobs", __dir__)
$LOAD_PATH.unshift(jobs_dir) unless $LOAD_PATH.include?(jobs_dir)

# Load supporting utils and job classes so Sidekiq can constantize them
require_relative "utils/utils"

# Eager-load all job classes under ./jobs (including subdirectories)
Dir[File.expand_path("jobs/**/*.rb", __dir__)].sort.each do |job_file|
  require job_file
end
