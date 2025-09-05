# frozen_string_literal: true

require "bundler/setup"
begin
  require "dotenv/load"
rescue LoadError
end

require "securerandom"
require "sidekiq/web"
require "rack"
require "rack/session"

# Session for CSRF protection
secret = ENV.fetch("SIDEKIQ_SESSION_SECRET", SecureRandom.hex(32))
use Rack::Session::Cookie, secret: secret, same_site: true, max_age: 86_400

# Optional HTTP Basic auth
if ENV["SIDEKIQ_WEB_USER"] && ENV["SIDEKIQ_WEB_PASSWORD"]
  require "rack/auth/basic"
  use Rack::Auth::Basic do |user, pass|
    user == ENV["SIDEKIQ_WEB_USER"] && pass == ENV["SIDEKIQ_WEB_PASSWORD"]
  end
end

run Sidekiq::Web
