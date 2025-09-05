# frozen_string_literal: true

module NittyMail
  # Base error is defined in lib/NittyMail.rb as NittyMail::Error

  # Raised when a mailbox lacks a UIDVALIDITY value during preflight/sync
  class MissingUIDValidityError < Error
    attr_reader :mailbox

    def initialize(mailbox)
      @mailbox = mailbox
      super("UIDVALIDITY missing for mailbox #{mailbox}")
    end
  end

  # Raised when trying to fetch more uids than the max_fetch_size
  class MaxFetchSizeError < Error
    attr_reader :mailbox

    def initialize(size, max)
      @mailbox = mailbox
      super("Max fetch size exceeded: #{size} > #{max}")
    end
  end
end
