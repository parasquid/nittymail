require "spec_helper"

RSpec.describe "CLI mailbox download" do
  Given(:address) { "test@example.com" }
  Given(:password) { "secret" }
  Given(:mailbox_stub) { double("NittyMail::Mailbox") }

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password

    require_relative "../../commands/mailbox/download"

    # Stub nittymail Mailbox
    allow(NittyMail::Mailbox).to receive(:new).and_return(mailbox_stub)
    allow(NittyMail::DB).to receive(:establish_sqlite_connection)
    allow(NittyMail::DB).to receive(:run_migrations!)
    allow(NittyMail::Email).to receive(:where).and_return([])
  end

  context "missing credentials" do
    before do
      ENV.delete("NITTYMAIL_IMAP_ADDRESS")
      ENV.delete("NITTYMAIL_IMAP_PASSWORD")
    end

    Then "raises ArgumentError for missing credentials" do
      download_cmd = NittyMail::Commands::MailboxDownload.new
      expect { download_cmd.invoke(:download, [], {}) }.to raise_error(SystemExit)
    end
  end

  context "purge mode" do
    before do
      allow(NittyMail::Email).to receive(:where).and_return(double(delete_all: 5))
      allow(mailbox_stub).to receive(:preflight).and_return({uidvalidity: 123, to_fetch: [], server_size: 0})
    end

    Then "handles purge mode correctly" do
      download_cmd = NittyMail::Commands::MailboxDownload.new
      expect { download_cmd.invoke(:download, [], {purge_uidvalidity: 123, yes: true}) }.not_to raise_error
    end
  end

  context "no emails to download" do
    before do
      allow(mailbox_stub).to receive(:preflight).and_return({
        uidvalidity: 123,
        to_fetch: [],
        server_size: 0
      })
    end

    Then "handles empty download gracefully" do
      download_cmd = NittyMail::Commands::MailboxDownload.new
      expect { download_cmd.invoke(:download, [], {database: ":memory:"}) }.not_to raise_error
    end
  end

  context "recreate mode" do
    before do
      allow(mailbox_stub).to receive(:preflight).and_return({
        uidvalidity: 123,
        to_fetch: [],
        server_size: 0
      })
      # Create a mock that handles both delete_all and pluck
      email_query_mock = double("EmailQuery")
      allow(email_query_mock).to receive(:delete_all).and_return(3)
      allow(email_query_mock).to receive(:pluck).with(:uid).and_return([])
      allow(NittyMail::Email).to receive(:where).and_return(email_query_mock)
      allow(NittyMail::DB).to receive(:establish_sqlite_connection)
      allow(NittyMail::DB).to receive(:run_migrations!)
    end

    Then "handles recreate mode correctly" do
      download_cmd = NittyMail::Commands::MailboxDownload.new
      expect { download_cmd.invoke(:download, [], {recreate: true, yes: true, database: ":memory:"}) }.not_to raise_error
    end
  end
end
