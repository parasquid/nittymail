require "spec_helper"

class RwMsg
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
      :"BODY[]" => @raw,
      "RFC822.SIZE" => @raw.bytesize,
      :"RFC822.SIZE" => @raw.bytesize
    }
  end
end

RSpec.describe "Recreate and purge" do
  Given(:address) { "recreate@example.com" }
  Given(:password) { "pw" }
  Given(:tmp_db) { File.expand_path("../../tmp/recreate.sqlite3", __dir__) }
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

  Then "recreate drops and re-downloads current generation" do
    # Seed DB with stale content for uidvalidity 8
    require_relative "../../utils/db"
    require_relative "../../models/email"
    NittyMail::DB.establish_sqlite_connection(database_path: tmp_db, address: address)
    NittyMail::DB.run_migrations!
    NittyMail::Email.create!(address: address, mailbox: "INBOX", uidvalidity: 8, uid: 1, subject: "OLD", internaldate: Time.at(1_700_000_000), internaldate_epoch: 1_700_000_000, raw: "raw")

    # Server returns uidvalidity 8 with uid 1
    allow(mailbox_stub).to receive(:preflight).and_return({uidvalidity: 8, to_fetch: [1], server_size: 1})
    m = RwMsg.new(uid: 1, t: Time.at(1_700_000_100), raw: "Subject: NEW\n\nBody")
    allow(mailbox_stub).to receive(:fetch) { |uids:| [m] }

    cli = NittyMail::Commands::Mailbox.new
    expect { cli.invoke(:download, [], {mailbox: "INBOX", recreate: true, yes: true}) }.not_to raise_error
    row = NittyMail::Email.where(address: address, mailbox: "INBOX", uidvalidity: 8, uid: 1).first
    expect(row).not_to be_nil
    expect(row.subject).to eq("NEW")
  end

  Then "purge deletes a target uidvalidity and exits" do
    require_relative "../../utils/db"
    require_relative "../../models/email"
    NittyMail::DB.establish_sqlite_connection(database_path: tmp_db, address: address)
    NittyMail::DB.run_migrations!
    NittyMail::Email.create!(address: address, mailbox: "INBOX", uidvalidity: 99, uid: 1, subject: "X", internaldate: Time.at(1_700_000_000), internaldate_epoch: 1_700_000_000, raw: "raw")

    # preflight still required; return some value (unused)
    allow(mailbox_stub).to receive(:preflight).and_return({uidvalidity: 9, to_fetch: [], server_size: 0})
    cli = NittyMail::Commands::Mailbox.new
    expect { cli.invoke(:download, [], {mailbox: "INBOX", purge_uidvalidity: 99, yes: true}) }.not_to raise_error
    expect(NittyMail::Email.where(address: address, mailbox: "INBOX", uidvalidity: 99).count).to eq(0)
  end
end
