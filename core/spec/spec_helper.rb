require "rspec/given"
require "dotenv/load"

# Load support helpers
Dir[File.join(__dir__, "support/**/*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
