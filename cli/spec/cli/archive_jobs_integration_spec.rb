require "spec_helper"
require "fileutils"
require "redis"
require "active_job"

class InMemoryRedisArc
  def initialize
    @data = {}
  end

  def ping
    "PONG"
  end

  def set(k, v)
    @data[k] = v.to_s
  end

  def get(k)
    @data[k]
  end

  def incr(k)
    @data[k] = (@data[k].to_i + 1).to_s
  end

  attr_reader :data
end

class AJMsg
  def initialize(uid:, body:)
    @uid = uid
    @raw = body
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

RSpec.describe "Archive jobs integration" do
  Given(:address) { "arcjobs@example.com" }
  Given(:password) { "pw" }
  Given(:mailbox) { "INBOX" }
  Given(:uids) { [41, 42, 43] }
  Given(:archive_base) { File.expand_path("../../archives", __dir__) }
  Given(:uv_dir) do
    require_relative "../../utils/utils"
    File.join(archive_base, address.downcase, NittyMail::Utils.sanitize_collection_name(mailbox), "66")
  end

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password
    FileUtils.rm_rf(archive_base)
    FileUtils.mkdir_p(archive_base)
    File.write(File.join(archive_base, ".keep"), "keep")

    # Use Active Job test adapter inline
    ActiveJob::Base.queue_adapter = :test
    allow(ActiveJob::Base).to receive(:queue_adapter=).and_return(nil)

    # Stub Redis client
    @redis = InMemoryRedisArc.new
    allow(::Redis).to receive(:new).and_return(@redis)

    # Stub mailbox
    require_relative "../../commands/mailbox"
    @mb = instance_double("NittyMail::Mailbox")
    allow(NittyMail::Mailbox).to receive(:new).and_return(@mb)
    allow(@mb).to receive(:preflight).and_return({uidvalidity: 66, to_fetch: uids, server_size: uids.size})
    msgs = uids.map { |u| AJMsg.new(uid: u, body: "Subject: S#{u}\n\nB#{u}") }
    allow(@mb).to receive(:fetch) { |uids:| msgs.select { |m| uids.include?(m.attr["UID"]) } }
  end

  after do
    FileUtils.rm_rf(archive_base)
  rescue
  end

  it "writes files and updates counters" do
    cli = NittyMail::Commands::Mailbox.new
    expect { cli.invoke(:archive, [], {mailbox: mailbox}) }.not_to raise_error
    expect(Dir.children(uv_dir).grep(/\.eml\z/).size).to eq(uids.size)
    key_total = @redis.data.keys.find { |k| k.include?("nm:arc:") && k.end_with?(":total") }
    key_processed = @redis.data.keys.find { |k| k.include?("nm:arc:") && k.end_with?(":processed") }
    key_errors = @redis.data.keys.find { |k| k.include?("nm:arc:") && k.end_with?(":errors") }
    expect(@redis.get(key_total).to_i).to eq(uids.size)
    expect(@redis.get(key_processed).to_i).to eq(uids.size)
    expect(@redis.get(key_errors).to_i).to eq(0)
  end
end
