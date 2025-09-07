require "spec_helper"

class BadMsg
  def initialize(uid:, t:, raw:)
    @uid = uid
    @t = t
    @raw = raw
  end

  def attr
    {
      "UID" => @uid,
      :UID => @uid,
      "INTERNALDATE" => @t,
      :INTERNALDATE => @t,
      "BODY[]" => @raw,
      :'BODY[]' => @raw
    }
  end
end

RSpec.describe "Strict mode" do
  Given(:address) { "strict@example.com" }
  Given(:password) { "pw" }
  Given(:tmp_db) { File.expand_path("../../tmp/strict.sqlite3", __dir__) }
  Given(:mailbox_stub) { instance_double("NittyMail::Mailbox") }

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password
    ENV["NITTYMAIL_SQLITE_DB"] = tmp_db
    require_relative "../../commands/mailbox"
    allow(NittyMail::Mailbox).to receive(:new).and_return(mailbox_stub)
  end

  after do
    File.delete(tmp_db) if File.exist?(tmp_db)
    File.delete(tmp_db + "-wal") if File.exist?(tmp_db + "-wal")
    File.delete(tmp_db + "-shm") if File.exist?(tmp_db + "-shm")
  rescue
  end

  Then "raises on DB upsert error when --strict is true" do
    allow(mailbox_stub).to receive(:preflight).and_return({uidvalidity: 9, to_fetch: [100], server_size: 1})
    t = Time.at(1_700_000_000)
    raw = "Subject: Hi\n\nBody"
    allow(mailbox_stub).to receive(:fetch) { |uids:| [BadMsg.new(uid: 100, t: t, raw: raw)] }
    require_relative "../../models/email"
    allow(NittyMail::Email).to receive(:upsert_all).and_raise(ActiveRecord::StatementInvalid.new("boom"))

    require_relative "../../commands/mailbox/download"
    cli = NittyMail::Commands::MailboxDownload.new
    expect { cli.invoke(:download, [], {mailbox: "INBOX", strict: true}) }.to raise_error(SystemExit)
  end
end
