require "spec_helper"
require "fileutils"
require "redis"
require "active_job"

class InMemoryRedis3
  def ping
    "PONG"
  end

  def set(*)
  end

  def get(*)
  end

  def incr(*)
  end
end

class JMS
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

RSpec.describe "Jobs strict mode" do
  Given(:address) { "jobsstrict@example.com" }
  Given(:password) { "pw" }
  Given(:mailbox) { "INBOX" }

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password
    ENV["NITTYMAIL_SQLITE_DB"] = File.expand_path("../../tmp/jobsstrict.sqlite3", __dir__)

    ActiveJob::Base.queue_adapter = :test
    adapter = ActiveJob::Base.queue_adapter
    if adapter.respond_to?(:perform_enqueued_jobs=)
      adapter.perform_enqueued_jobs = true
      adapter.perform_enqueued_at_jobs = true if adapter.respond_to?(:perform_enqueued_at_jobs=)
    end
    allow(ActiveJob::Base).to receive(:queue_adapter=).and_return(nil)
    allow(::Redis).to receive(:new).and_return(InMemoryRedis3.new)
    require_relative "../../commands/mailbox"
  end

  after do
    db = ENV["NITTYMAIL_SQLITE_DB"]
    [db, db + "-wal", db + "-shm"].each { |p| File.delete(p) if p && File.exist?(p) }
    FileUtils.rm_rf(File.expand_path("../../job-data", __dir__))
  rescue
  end

  it "raises when WriteJob upsert fails with --strict" do
    require_relative "../../commands/mailbox/download"
    mb = instance_double("NittyMail::Mailbox")
    allow(NittyMail::Mailbox).to receive(:new).and_return(mb)
    allow(mb).to receive(:preflight).and_return({uidvalidity: 77, to_fetch: [1], server_size: 1})
    allow(mb).to receive(:fetch) { |uids:| [JMS.new(uid: 1, t: Time.at(1_700_000_000))] }

    require_relative "../../models/email"
    allow(NittyMail::Email).to receive(:upsert_all).and_raise(ActiveRecord::StatementInvalid.new("boom"))

    cli = NittyMail::Commands::MailboxDownload.new
    expect do
      cli.invoke(:download, [], {mailbox: mailbox, strict: true})
    end.to raise_error(SystemExit)
  end

  it "raises when FetchJob fetch fails with --strict" do
    require_relative "../../commands/mailbox/download"
    mb = instance_double("NittyMail::Mailbox")
    allow(NittyMail::Mailbox).to receive(:new).and_return(mb)
    allow(mb).to receive(:preflight).and_return({uidvalidity: 77, to_fetch: [1, 2], server_size: 2})
    allow(mb).to receive(:fetch).and_raise(StandardError.new("imap boom"))

    cli = NittyMail::Commands::MailboxDownload.new
    expect do
      cli.invoke(:download, [], {mailbox: mailbox, strict: true})
    end.to raise_error(SystemExit)
  end
end
