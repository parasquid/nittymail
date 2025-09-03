# frozen_string_literal: true

require "spec_helper"

RSpec.describe NittyMail::MissingUIDValidityError do
  context "message and data" do
    Given(:mailbox) { "INBOX" }
    Given(:error) { described_class.new(mailbox) }
    Then { expect(error.message).to match(/UIDVALIDITY missing for mailbox INBOX/) }
    And { expect(error.mailbox).to eq(mailbox) }
    And { expect { raise error }.to raise_error(described_class, /INBOX/) }
  end
end
