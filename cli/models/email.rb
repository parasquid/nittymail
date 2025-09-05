# frozen_string_literal: true

require "active_record"

module NittyMail
  class Email < ActiveRecord::Base
    self.table_name = "emails"

    validates :address, :mailbox, :uidvalidity, :uid, :internaldate, :internaldate_epoch, :raw, presence: true

    # Useful composite uniqueness validation (best-effort; DB index enforces definitively)
    validates :uid, uniqueness: {scope: [:address, :mailbox, :uidvalidity]}
  end
end
