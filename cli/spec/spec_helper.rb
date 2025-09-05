# frozen_string_literal: true

require "rspec/given"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

end
