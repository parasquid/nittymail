require "spec_helper"
require "fileutils"

class ARStubMsg
  def initialize(uid:, raw:)
    @uid = uid
    @raw = raw
  end

  def attr
    {
      "UID" => @uid,
      :UID => @uid,
      "BODY[]" => @raw,
      :"BODY[]" => @raw,
      "RFC822.SIZE" => @raw.bytesize,
      :"RFC822.SIZE" => @raw.bytesize
    }
  end
end

RSpec.describe "Archive resumability" do
  Given(:address) { "resume-arc@example.com" }
  Given(:password) { "pw" }
  Given(:mailbox) { "INBOX" }
  Given(:archive_base) { File.expand_path("../../archives", __dir__) }
  Given(:uv_dir) do
    require_relative "../../utils/utils"
    File.join(archive_base, address.downcase, NittyMail::Utils.sanitize_collection_name(mailbox), "88")
  end

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password
    FileUtils.rm_rf(archive_base)
    FileUtils.mkdir_p(uv_dir)
    File.write(File.join(archive_base, ".keep"), "keep")
    # Pre-create one archived file
    File.write(File.join(uv_dir, "21.eml"), "Subject: OLD\n\nBody")

    require_relative "../../commands/mailbox"
    @mb = instance_double("NittyMail::Mailbox")
    allow(NittyMail::Mailbox).to receive(:new).and_return(@mb)
    allow(@mb).to receive(:preflight).and_return({uidvalidity: 88, to_fetch: [21, 22, 23], server_size: 3})
    msgs = [
      ARStubMsg.new(uid: 21, raw: "Subject: S21\n\nB21"),
      ARStubMsg.new(uid: 22, raw: "Subject: S22\n\nB22"),
      ARStubMsg.new(uid: 23, raw: "Subject: S23\n\nB23")
    ]
    allow(@mb).to receive(:fetch) { |uids:| msgs.select { |m| uids.include?(m.attr["UID"]) } }
  end

  after do
    FileUtils.rm_rf(archive_base)
  rescue
  end

  Then "skips existing UID files and writes missing ones" do
    require_relative "../../commands/mailbox/archive"
    cli = NittyMail::Commands::MailboxArchive.new
    expect { cli.invoke(:archive, [], {mailbox: mailbox}) }.not_to raise_error
    expect(File.exist?(File.join(uv_dir, "21.eml"))).to eq(true)
    expect(File.exist?(File.join(uv_dir, "22.eml"))).to eq(true)
    expect(File.exist?(File.join(uv_dir, "23.eml"))).to eq(true)
  end
end
