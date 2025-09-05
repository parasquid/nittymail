# frozen_string_literal: true

require "rspec/given"
require "active_job"

# Use Active Job's test adapter in specs for deterministic behavior
ActiveJob::Base.queue_adapter = :test

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
