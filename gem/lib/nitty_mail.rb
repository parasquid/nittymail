# frozen_string_literal: true

require_relative "nitty_mail/version"

module NittyMail
  class Error < StandardError; end
  # Your code goes here...
end

require_relative "nitty_mail/settings"
require_relative "nitty_mail/errors"
require_relative "nitty_mail/mailbox"
require_relative "nitty_mail/utils"
