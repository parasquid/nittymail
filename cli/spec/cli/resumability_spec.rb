require "spec_helper"

class RMsg
  def initialize(uid:, t:, subj:, body:)
    @uid = uid
    @t = t
    @raw = "Subject: #{subj}\n\n#{body}"
  end

  def attr
    {
      "UID" => @uid,
      :UID => @uid,
      "INTERNALDATE" => @t,
      :INTERNALDATE => @t,
      "BODY[]" => @raw,
      :'BODY[]' => @raw,
      "RFC822.SIZE" => @raw.bytesize,
      :'RFC822.SIZE' => @raw.bytesize,
      "ENVELOPE" => nil,
      :ENVELOPE => nil
    }
  end
end

RSpec.describe "Resumability" do
  Given(:address) { "resume@example.com" }
  Given(:password) { "pw" }
  Given(:tmp_db) { "/tmp/test-resume-#{Process.pid}.sqlite3" }
  Given(:mailbox_stub) { instance_double("NittyMail::Mailbox") }

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password
    ENV["NITTYMAIL_SQLITE_DB"] = tmp_db

    require_relative "../../commands/mailbox"
    allow(NittyMail::Mailbox).to receive(:new).and_return(mailbox_stub)

    t = Time.at(1_700_000_000)
    @msgs = [RMsg.new(uid: 10, t: t, subj: "S1", body: "A"), RMsg.new(uid: 11, t: t + 10, subj: "S2", body: "B")]
    allow(mailbox_stub).to receive(:preflight).and_return({uidvalidity: 5, to_fetch: [10, 11], server_size: 2})
    allow(mailbox_stub).to receive(:fetch) do |uids:|
      @msgs.select { |m| uids.include?(m.attr["UID"]) }
    end
  end

  after do
    File.delete(tmp_db) if File.exist?(tmp_db)
    File.delete(tmp_db + "-wal") if File.exist?(tmp_db + "-wal")
    File.delete(tmp_db + "-shm") if File.exist?(tmp_db + "-shm")
  rescue
  end

  Then "fetches only missing UIDs when DB already has some" do
    # Pre-populate DB with two rows (uids 10,11)
    require_relative "../../utils/db"
    require_relative "../../models/email"
    NittyMail::DB.establish_sqlite_connection(database_path: tmp_db, address: address)
    NittyMail::DB.run_migrations!
    NittyMail::Email.create!(address: address, mailbox: "INBOX", uidvalidity: 5, uid: 10, subject: "S1", internaldate: Time.at(1_700_000_000), internaldate_epoch: 1_700_000_000, raw: "raw")
    NittyMail::Email.create!(address: address, mailbox: "INBOX", uidvalidity: 5, uid: 11, subject: "S2", internaldate: Time.at(1_700_000_010), internaldate_epoch: 1_700_000_010, raw: "raw")

    # Server now has 10,11,12,13
    t = Time.at(1_700_000_000)
    @msgs = [RMsg.new(uid: 10, t: t, subj: "S1", body: "A"), RMsg.new(uid: 11, t: t + 10, subj: "S2", body: "B"), RMsg.new(uid: 12, t: t + 20, subj: "S3", body: "C"), RMsg.new(uid: 13, t: t + 30, subj: "S4", body: "D")]
    allow(mailbox_stub).to receive(:preflight).and_return({uidvalidity: 5, to_fetch: [10, 11, 12, 13], server_size: 4})

    cli = NittyMail::Commands::Mailbox.new
    expect { cli.invoke(:download, [], {mailbox: "INBOX"}) }.not_to raise_error
    uids = NittyMail::Email.where(uidvalidity: 5).order(:uid).pluck(:uid)
    expect(uids).to eq([10, 11, 12, 13])
  end
end
