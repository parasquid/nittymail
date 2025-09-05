require "spec_helper"

RSpec.describe "CLI mailbox smoke" do
  class StubMsg
    def initialize(uid:, internaldate:, raw:, size: 123, labels: [], envelope_from: nil)
      @uid = uid
      @internaldate = internaldate
      @raw = raw
      @size = size
      @labels = labels
      @envelope_from = envelope_from
    end

    def attr
      {
        "UID" => @uid,
        :UID => @uid,
        "INTERNALDATE" => @internaldate,
        :INTERNALDATE => @internaldate,
        "BODY[]" => @raw,
        :'BODY[]' => @raw,
        "RFC822.SIZE" => @size,
        :'RFC822.SIZE' => @size,
        "X-GM-LABELS" => @labels,
        :'X-GM-LABELS' => @labels,
        :x_gm_labels => @labels,
        "ENVELOPE" => @envelope_from,
        :ENVELOPE => @envelope_from,
        :envelope => @envelope_from
      }
    end
  end

  class StubAddress
    attr_reader :mailbox, :host
    def initialize(addr)
      @mailbox, @host = addr.split("@", 2)
    end
  end

  class StubEnvelope
    attr_reader :from
    def initialize(addr)
      @from = [StubAddress.new(addr)]
    end
  end

  Given(:address) { "smoke@example.com" }
  Given(:password) { "secret" }
  Given(:tmp_db) { File.expand_path("../../tmp/smoke.sqlite3", __dir__) }

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password
    ENV["NITTYMAIL_SQLITE_DB"] = tmp_db

    require_relative "../../commands/mailbox"

    # Stub nittymail Mailbox
    stubbed = instance_double("NittyMail::Mailbox")
    allow(NittyMail::Mailbox).to receive(:new).and_return(stubbed)
    allow(stubbed).to receive(:preflight).and_return({uidvalidity: 7, to_fetch: [1, 2], server_size: 2})

    t = Time.at(1_700_000_000)
    raw1 = "Subject: Hello A\n\nBody A"
    raw2 = "Subject: Hello B\n\nBody B"
    env = StubEnvelope.new("from@test.dev")
    msgs = [
      StubMsg.new(uid: 1, internaldate: t, raw: raw1, envelope_from: env),
      StubMsg.new(uid: 2, internaldate: t + 60, raw: raw2, envelope_from: env)
    ]
    allow(stubbed).to receive(:fetch) do |uids:|
      msgs.select { |m| uids.include?(m.attr["UID"]) }
    end
  end

  after do
    File.delete(tmp_db) if File.exist?(tmp_db)
    File.delete(tmp_db + "-wal") if File.exist?(tmp_db + "-wal")
    File.delete(tmp_db + "-shm") if File.exist?(tmp_db + "-shm")
  rescue
  end

  context "download" do
    Then "writes rows and is idempotent" do
      cli = NittyMail::Commands::Mailbox.new
      expect { cli.invoke(:download, [], {mailbox: "INBOX"}) }.not_to raise_error

      require_relative "../../models/email"
      expect(NittyMail::Email.count).to eq(2)
      subjects = NittyMail::Email.order(:uid).pluck(:subject)
      expect(subjects).to eq(["Hello A", "Hello B"])

      # run again; should upsert and keep count stable
      expect { cli.invoke(:download, [], {mailbox: "INBOX"}) }.not_to raise_error
      expect(NittyMail::Email.count).to eq(2)
    end
  end
end
