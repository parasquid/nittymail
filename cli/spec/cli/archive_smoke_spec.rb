require "spec_helper"
require "fileutils"

class AStubMsg
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
      :'RFC822.SIZE' => @raw.bytesize
    }
  end
end

RSpec.describe "Archive smoke" do
  Given(:address) { "archive@example.com" }
  Given(:password) { "pw" }
  Given(:mailbox) { "INBOX" }
  Given(:archive_base) { "/app/archives" }
  Given(:uv_dir) do
    require_relative "../../utils/utils"
    File.join(archive_base, address.downcase, NittyMail::Utils.sanitize_collection_name(mailbox), "77")
  end

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password
    FileUtils.rm_rf(archive_base)
    FileUtils.mkdir_p(archive_base)
    File.write(File.join(archive_base, ".keep"), "keep")
    require_relative "../../commands/mailbox"
    @mb = instance_double("NittyMail::Mailbox")
    allow(NittyMail::Mailbox).to receive(:new).and_return(@mb)
    allow(@mb).to receive(:preflight).and_return({uidvalidity: 77, to_fetch: [11, 12], server_size: 2})
    t = Time.at(1_700_000_000)
    msgs = [AStubMsg.new(uid: 11, t: t, subj: "A", body: "X"), AStubMsg.new(uid: 12, t: t + 5, subj: "B", body: "Y")]
    allow(@mb).to receive(:fetch) { |uids:| msgs.select { |m| uids.include?(m.attr["UID"]) } }
  end

  after do
    FileUtils.rm_rf(archive_base)
  rescue
  end

  Then "archives files and is idempotent" do
    cli = NittyMail::Commands::Mailbox.new
    expect { cli.invoke(:archive, [], {mailbox: mailbox, address: address}) }.not_to raise_error
    expect(File.exist?(File.join(uv_dir, "11.eml"))).to eq(true)
    expect(File.exist?(File.join(uv_dir, "12.eml"))).to eq(true)
    raw = File.binread(File.join(uv_dir, "11.eml"))
    expect(raw).to include("Subject: A")

    # run again should not duplicate or error
    expect { cli.invoke(:archive, [], {mailbox: mailbox}) }.not_to raise_error
    expect(Dir.children(uv_dir).grep(/\.eml\z/).size).to eq(2)
  end
end
