# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "fileutils"

require_relative "../sync"
require_relative "../lib/nittymail/imap_tape"
require_relative "../lib/nittymail/db"

class CollectingReporter < NittyMail::Reporting::BaseReporter
  attr_reader :events
  def initialize(*)
    super
    @events = []
  end

  def event(type, payload = {})
    @events << [type.to_sym, payload]
    super
  end
end

RSpec.describe "Integration: sync with IMAP tape" do
  cassette_path = File.join(__dir__, "cassettes", "imap_sync.json")
  Given(:tape) { NittyMail::IMAPTape.new(cassette_path) }
  Given(:reporter) { CollectingReporter.new }
  Given(:db_copy) do
    src = File.expand_path("../data/query_given.sqlite3", __dir__)
    dest = File.expand_path("../data/test.sqlite3", __dir__)
    if File.exist?(src)
      FileUtils.cp(src, dest)
    else
      # Create a minimal empty database with required schema
      db = NittyMail::DB.connect(dest, wal: false, load_vec: true)
      NittyMail::DB.ensure_schema!(db)
      NittyMail::DB.ensure_query_indexes!(db)
      db.disconnect
    end
    dest
  end

  after(:each) do
    # Clean up test database and any WAL/SHM side files
    paths = [db_copy, "#{db_copy}-wal", "#{db_copy}-shm"]
    paths.each { |p| FileUtils.rm_f(p) if p && !p.empty? }
  end

  Invariant do
    # Ensure environment has minimal config for live recording when requested
    if ENV["INTEGRATION_RECORD"]
      %w[ADDRESS PASSWORD].each do |k|
        skip("set #{k} to record integration cassette") unless ENV[k]
      end
    end
  end

  context "replay from cassette" do
    Given do
      skip("no cassette present; set INTEGRATION_RECORD=1 to record one") unless File.exist?(cassette_path)

      # Stub preflight to replay from tape
      allow(NittyMail::Preflight).to receive(:compute) do |imap, email_ds, mbox_name, db_mutex|
        tape.replay_preflight(mbox_name)
      end

      # Prevent real network/login during replay
      allow_any_instance_of(NittyMail::IMAPClient).to receive(:reconnect_and_select).and_return(true)

      # Avoid Mail.connection network access; return mailboxes from cassette
      fake_imap = double("FakeIMAP")
      allow(fake_imap).to receive(:list) do |prefix, pattern|
        tape_mailboxes = tape.data.fetch("preflight").keys
        tape_mailboxes.map { |name| OpenStruct.new(name: name, attr: []) }
      end
      allow(Mail).to receive(:connection).and_yield(fake_imap)

      # Bypass real Net::IMAP usage in preflight workers
      allow_any_instance_of(NittyMail::Sync).to receive(:run_preflight_worker) do |inst, imap_address, imap_password, email, mbox_queue, preflight_results, preflight_mutex, reporter, db_mutex|
        NittyMail::SyncUtils.preflight_worker_with_imap(nil, email, mbox_queue, preflight_results, preflight_mutex, reporter, db_mutex)
      end

      # Stub IMAP client fetch to replay from tape
      allow_any_instance_of(NittyMail::IMAPClient).to receive(:fetch_with_retry) do |inst, uids, items, mailbox_name:, expected_uidvalidity:, retry_attempts:, progress:|
        tape.replay_fetch(mailbox_name, uids)
      end
    end

    When do
      NittyMail::Sync.perform(
        imap_address: "ignored@example.com",
        imap_password: "ignored",
        database_path: db_copy,
        threads_count: 1,
        mailbox_threads: 1,
        auto_confirm: true,
        reporter: reporter
      )
    end

    Then { (reporter.events.map(&:first) & [:mailbox_summary, :mailbox_skipped]).any? }
  end

  context "record to cassette" do
    # Use a human-friendly reporter during recording for visible logs
    Given(:reporter) do
      if ENV["INTEGRATION_LOG_JSON"]
        Class.new(NittyMail::Reporting::BaseReporter) do
          def event(type, payload = {})
            puts({event: type, **payload}.to_json)
          end
        end.new
      elsif ENV["INTEGRATION_LOG"] || !STDOUT.tty?
        NittyMail::Reporting::TextReporter.new(quiet: false)
      else
        NittyMail::Reporting::CLIReporter.new(quiet: false)
      end
    end
    Given do
      skip("recording disabled; set INTEGRATION_RECORD=1 to enable") unless ENV["INTEGRATION_RECORD"]

      # Wrap live calls and record to tape
      orig_compute = NittyMail::Preflight.method(:compute)
      allow(NittyMail::Preflight).to receive(:compute) do |imap, email_ds, mbox_name, db_mutex|
        res = orig_compute.call(imap, email_ds, mbox_name, db_mutex)
        tape.record_preflight(mbox_name, res)
        puts "[cassette] preflight recorded: mailbox=#{mbox_name} to_fetch=#{res[:to_fetch].size} to_prune=#{res[:db_only].size}" if ENV["INTEGRATION_VERBOSE"]
        res
      end

      allow_any_instance_of(NittyMail::IMAPClient).to receive(:fetch_with_retry).and_wrap_original do |m, *args, **kwargs|
        res = m.call(*args, **kwargs)
        # Serialize attrs for tape (record full bodies by default)
        serial = res.map { |fd| {"attr" => fd.attr.dup} }
        tape.record_fetch(kwargs[:mailbox_name], args.first, serial)
        uids = Array(args.first)
        ukey = if uids.size > 1 && uids.each_cons(2).all? { |a, b| b.to_i == a.to_i + 1 }
          "#{uids.first}-#{uids.last}"
        else
          uids.join(',')
        end
        puts "[cassette] fetch recorded: mailbox=#{kwargs[:mailbox_name]} uids=#{ukey} count=#{serial.length}" if ENV["INTEGRATION_VERBOSE"]
        res
      end
    end

    When do
      only_mbs = ENV["ONLY_MAILBOXES"]&.split(",")&.map(&:strip) || ["INBOX"]
      NittyMail::Sync.perform(
        imap_address: ENV["ADDRESS"],
        imap_password: ENV["PASSWORD"],
        database_path: db_copy,
        threads_count: 1,
        mailbox_threads: 1,
        auto_confirm: true,
        reporter: reporter,
        only_mailboxes: only_mbs
      )
    end

    Then { File.exist?(cassette_path) }
  end
end
