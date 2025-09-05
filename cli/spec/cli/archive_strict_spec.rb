require "spec_helper"
require "fileutils"

class ASMsg
  def initialize(uid:, raw:)
    @uid = uid
    @raw = raw
  end

  def attr
    {"UID" => @uid, :UID => @uid, "BODY[]" => @raw, :"BODY[]" => @raw, "RFC822.SIZE" => @raw.bytesize, :"RFC822.SIZE" => @raw.bytesize}
  end
end

RSpec.describe "Archive strict mode" do
  Given(:address) { "arcstrict@example.com" }
  Given(:password) { "pw" }
  Given(:mailbox) { "INBOX" }

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password
    require_relative "../../commands/mailbox"
  end

  it "raises SystemExit when fetch fails in strict mode (no-jobs)" do
    mb = instance_double("NittyMail::Mailbox")
    allow(NittyMail::Mailbox).to receive(:new).and_return(mb)
    allow(mb).to receive(:preflight).and_return({uidvalidity: 90, to_fetch: [1, 2], server_size: 2})
    allow(mb).to receive(:fetch).and_raise(StandardError.new("imap boom"))
    cli = NittyMail::Commands::Mailbox.new
    expect { cli.invoke(:archive, [], {mailbox: mailbox, no_jobs: true, strict: true}) }.to raise_error(SystemExit)
  end

  it "raises SystemExit when job write fails in strict mode (jobs)" do
    # Use jobs mode with Active Job test adapter
    require "active_job"
    ActiveJob::Base.queue_adapter = :test
    allow(ActiveJob::Base).to receive(:queue_adapter=).and_return(nil)
    # Redis stub
    require "redis"
    r = double("Redis", ping: "PONG", set: true, get: "0")
    allow(::Redis).to receive(:new).and_return(r)
    # Mailbox preflight + fetch
    mb = instance_double("NittyMail::Mailbox")
    allow(NittyMail::Mailbox).to receive(:new).and_return(mb)
    allow(mb).to receive(:preflight).and_return({uidvalidity: 91, to_fetch: [5], server_size: 1})
    msg = ASMsg.new(uid: 5, raw: "Subject: X\n\nBody")
    allow(mb).to receive(:fetch).and_return([msg])
    # Force write failure by stubbing File.rename to raise during job execution
    allow(File).to receive(:rename).and_raise(StandardError.new("disk boom"))

    cli = NittyMail::Commands::Mailbox.new
    expect { cli.invoke(:archive, [], {mailbox: mailbox, strict: true}) }.to raise_error(SystemExit)
  end
end
