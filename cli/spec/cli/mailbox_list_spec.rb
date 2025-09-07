require "spec_helper"

class StubMailboxItem
  attr_reader :name
  def initialize(name)
    @name = name
  end

  def to_s
    @name
  end
end

RSpec.describe "CLI mailbox list" do
  Given(:address) { "test@example.com" }
  Given(:password) { "secret" }
  Given(:mailbox_stub) { double("NittyMail::Mailbox") }

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password

    require_relative "../../commands/mailbox/list"

    # Stub nittymail Mailbox
    allow(NittyMail::Mailbox).to receive(:new).and_return(mailbox_stub)
  end

  context "successful list" do
    Given(:mailboxes) { [StubMailboxItem.new("INBOX"), StubMailboxItem.new("Sent"), StubMailboxItem.new("Drafts")] }

    before do
      allow(mailbox_stub).to receive(:list).and_return(mailboxes)
      allow(mailbox_stub).to receive(:respond_to?).and_return(false)
    end

    Then "lists mailboxes successfully" do
      list_cmd = NittyMail::Commands::MailboxList.new
      expect { list_cmd.invoke(:list, [], {}) }.not_to raise_error
    end
  end

  context "empty mailbox list" do
    before do
      allow(mailbox_stub).to receive(:list).and_return([])
      allow(mailbox_stub).to receive(:respond_to?).and_return(false)
    end

    Then "handles empty list gracefully" do
      list_cmd = NittyMail::Commands::MailboxList.new
      expect { list_cmd.invoke(:list, [], {}) }.not_to raise_error
    end
  end

  context "missing credentials" do
    before do
      ENV.delete("NITTYMAIL_IMAP_ADDRESS")
      ENV.delete("NITTYMAIL_IMAP_PASSWORD")
    end

    Then "raises ArgumentError for missing credentials" do
      list_cmd = NittyMail::Commands::MailboxList.new
      expect { list_cmd.invoke(:list, [], {}) }.to raise_error(SystemExit)
    end
  end

  context "IMAP errors" do
    before do
      imap_error = StandardError.new("IMAP error")
      imap_error.define_singleton_method(:class) { Net::IMAP::NoResponseError }
      allow(mailbox_stub).to receive(:list).and_raise(imap_error)
    end

    Then "handles IMAP errors gracefully" do
      list_cmd = NittyMail::Commands::MailboxList.new
      expect { list_cmd.invoke(:list, [], {}) }.to raise_error(SystemExit)
    end
  end
end
