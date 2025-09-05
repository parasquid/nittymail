require "spec_helper"
require "fileutils"
require "redis"

class InMemoryRedis
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
end

class StubMsgI
  def initialize(uid:, t:)
    @uid = uid
    @t = t
  end

  def attr
    {
      "UID" => @uid,
      :UID => @uid,
      "INTERNALDATE" => @t,
      :INTERNALDATE => @t,
      "BODY[]" => "Subject: X\n\nBody",
      :'BODY[]' => "Subject: X\n\nBody",
      "RFC822.SIZE" => 10,
      :'RFC822.SIZE' => 10
    }
  end
end

RSpec.describe "Jobs mode interrupts" do
  Given(:address) { "jobsint@example.com" }
  Given(:password) { "pw" }
  Given(:mailbox) { "INBOX" }
  Given(:uidvalidity) { 42 }
  Given(:uids) { [1, 2, 3] }
  Given(:uv_dir) do
    base = File.expand_path("../../job-data", __dir__)
    safe_address = address.downcase
    require_relative "../../utils/utils"
    safe_mailbox = NittyMail::Utils.sanitize_collection_name(mailbox)
    File.join(base, safe_address, safe_mailbox, uidvalidity.to_s)
  end

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password
    ENV["NITTYMAIL_SQLITE_DB"] = File.expand_path("../../tmp/jobsint.sqlite3", __dir__)

    # Ensure job-data dir and artifact files exist to be cleaned up on abort
    FileUtils.mkdir_p(uv_dir)
    uids.each { |u| File.write(File.join(uv_dir, "#{u}.eml"), "stub") }

    # Use Active Job test adapter and prevent switching to Sidekiq in CLI
    require "active_job"
    ActiveJob::Base.queue_adapter = :test
    allow(ActiveJob::Base).to receive(:queue_adapter=).and_return(nil)

    # Stub Redis client
    @redis = InMemoryRedis.new
    allow(::Redis).to receive(:new).and_return(@redis)

    # Stub mailbox
    require_relative "../../commands/mailbox"
    @mb = instance_double("NittyMail::Mailbox")
    allow(NittyMail::Mailbox).to receive(:new).and_return(@mb)
    allow(@mb).to receive(:preflight).and_return({uidvalidity: uidvalidity, to_fetch: uids, server_size: uids.size})
    allow(@mb).to receive(:fetch) { |uids:| uids.map { |u| StubMsgI.new(uid: u, t: Time.at(1_700_000_000)) } }
  end

  after do
    # Cleanup temp db and artifacts
    db = ENV["NITTYMAIL_SQLITE_DB"]
    [db, db + "-wal", db + "-shm"].each { |p| File.delete(p) if p && File.exist?(p) }
    FileUtils.rm_rf(File.expand_path("../../job-data", __dir__))
  rescue
  end

  it "handles single Ctrl-C by setting abort flag and cleaning artifacts" do
    cli = NittyMail::Commands::Mailbox.new
    thr = Thread.new do
      sleep 0.3
      Process.kill("INT", Process.pid)
    end
    expect { cli.invoke(:download, [], {mailbox: mailbox}) }.not_to raise_error
    thr.join

    # Redis abort flag should be set to 1 for the run_id used; detect any matching key
    aborted_keys = @redis.instance_variable_get(:@data).keys.grep(/nm:dl:.*:aborted/)
    expect(aborted_keys.size).to be >= 1
    expect(@redis.get(aborted_keys.first)).to eq("1")

    # Artifact files should be removed
    uids.each do |u|
      expect(File.exist?(File.join(uv_dir, "#{u}.eml"))).to eq(false)
    end
  end

  it "exits with 130 on double Ctrl-C" do
    cli = NittyMail::Commands::Mailbox.new
    thr = Thread.new do
      sleep 0.2
      Process.kill("INT", Process.pid)
      sleep 0.2
      Process.kill("INT", Process.pid)
    end
    begin
      expect { cli.invoke(:download, [], {mailbox: mailbox}) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(130) }
    ensure
      thr.join
    end
  end
end
