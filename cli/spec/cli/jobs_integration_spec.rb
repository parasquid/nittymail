require "spec_helper"
require "fileutils"
require "redis"
require "active_job"

class InMemoryRedis2
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

class JIMsg
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
      :"BODY[]" => @raw,
      "RFC822.SIZE" => @raw.bytesize,
      :"RFC822.SIZE" => @raw.bytesize
    }
  end
end

RSpec.describe "Jobs mode integration" do
  Given(:address) { "jobsint2@example.com" }
  Given(:password) { "pw" }
  Given(:mailbox) { "INBOX" }
  Given(:uids) { [101, 102, 103, 104] }
  Given(:tmp_db) { File.expand_path("../../tmp/jobsint2.sqlite3", __dir__) }

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password
    ENV["NITTYMAIL_SQLITE_DB"] = tmp_db

    # Active Job test adapter executes jobs inline within the block
    ActiveJob::Base.queue_adapter = :test
    adapter = ActiveJob::Base.queue_adapter
    if adapter.respond_to?(:perform_enqueued_jobs=)
      adapter.perform_enqueued_jobs = true
      adapter.perform_enqueued_at_jobs = true if adapter.respond_to?(:perform_enqueued_at_jobs=)
    end
    allow(ActiveJob::Base).to receive(:queue_adapter=).and_return(nil)

    # Stub Redis
    @redis = InMemoryRedis2.new
    allow(::Redis).to receive(:new).and_return(@redis)

    # Stub mailbox
    require_relative "../../commands/mailbox"
    @mb = instance_double("NittyMail::Mailbox")
    allow(NittyMail::Mailbox).to receive(:new).and_return(@mb)
    allow(@mb).to receive(:preflight).and_return({uidvalidity: 55, to_fetch: uids, server_size: uids.size})
    t = Time.at(1_700_000_000)
    msgs = uids.map.with_index { |u, i| JIMsg.new(uid: u, t: t + i, subj: "S#{i}", body: "B#{i}") }
    allow(@mb).to receive(:fetch) { |uids:| msgs.select { |m| uids.include?(m.attr["UID"]) } }
  end

  after do
    [tmp_db, tmp_db + "-wal", tmp_db + "-shm"].each { |p| File.delete(p) if File.exist?(p) }
    FileUtils.rm_rf(File.expand_path("../../job-data", __dir__))
  rescue
  end

  it "enqueues fetch+write jobs and writes all rows" do
    require_relative "../../models/email"
    cli = NittyMail::Commands::Mailbox.new
    expect { cli.invoke(:download, [], {mailbox: mailbox}) }.not_to raise_error
    expect(NittyMail::Email.count).to eq(uids.size)
    # counters reflect completion
    key_total = @redis.data.keys.find { |k| k.end_with?(":total") }
    key_processed = @redis.data.keys.find { |k| k.end_with?(":processed") }
    key_errors = @redis.data.keys.find { |k| k.end_with?(":errors") }
    expect(@redis.get(key_total).to_i).to eq(uids.size)
    expect(@redis.get(key_processed).to_i).to eq(uids.size)
    expect(@redis.get(key_errors).to_i).to eq(0)
    # artifacts cleaned
    base = File.expand_path("../../job-data", __dir__)
    expect(Dir.glob(File.join(base, "**/*.eml")).empty?).to eq(true)
  end
end
