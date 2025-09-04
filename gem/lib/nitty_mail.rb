# frozen_string_literal: true

require_relative "NittyMail/version"

module NittyMail
  class Error < StandardError; end
  # Your code goes here...
end

require_relative "NittyMail/settings"
require_relative "NittyMail/errors"
require_relative "NittyMail/mailbox"
