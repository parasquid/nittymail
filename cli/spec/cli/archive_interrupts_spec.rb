require "spec_helper"
require "fileutils"
require "redis"
require "active_job"

RSpec.describe "Archive jobs interrupts" do
  Given(:address) { "arcint@example.com" }
  Given(:password) { "pw" }
  Given(:mailbox) { "INBOX" }
  Given(:archive_base) { File.expand_path("../../archives", __dir__) }

  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password
    FileUtils.rm_rf(archive_base)
    FileUtils.mkdir_p(archive_base)
    File.write(File.join(archive_base, ".keep"), "keep")

    # Active Job test adapter
    ActiveJob::Base.queue_adapter = :test
    allow(ActiveJob::Base).to receive(:queue_adapter=).and_return(nil)
    # Redis stub
    @redis = Class.new {
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

      attr_reader :data
    }.new
    allow(::Redis).to receive(:new).and_return(@redis)

    # Mailbox stubs
    require_relative "../../commands/mailbox"
    @mb = instance_double("NittyMail::Mailbox")
    allow(NittyMail::Mailbox).to receive(:new).and_return(@mb)
    allow(@mb).to receive(:preflight).and_return({uidvalidity: 65, to_fetch: [7, 8, 9], server_size: 3})
    # Keep fetch simple
    def mkmsg(u)
      Class.new {
        def initialize(u)
          @u = u
        end

        def attr
          {"UID" => @u, :UID => @u, "BODY[]" => "X", :'BODY[]' => "X", "RFC822.SIZE" => 1, :'RFC822.SIZE' => 1}
        end
      }.new(u)
    end
    allow(@mb).to receive(:fetch) { |uids:| uids.map { |u| mkmsg(u) } }
  end

  after do
    FileUtils.rm_rf(archive_base)
  rescue
  end

  it "sets abort flag and stops; cleans tmp files" do
    cli = NittyMail::Commands::MailboxArchive.new
    thr = Thread.new do
      sleep 0.2
      Process.kill("INT", Process.pid)
    end
    expect { cli.invoke(:archive, [], {mailbox: mailbox}) }.not_to raise_error
    thr.join
    key = @redis.data.keys.find { |k| k.include?(":aborted") }
    expect(@redis.get(key)).to eq("1")
  end
end
