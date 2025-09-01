# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "fileutils"

require_relative "../sync"
require_relative "../lib/nittymail/imap_tape"

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
  cassette_path = File.expand_path("../spec/cassettes/imap_sync.json", __dir__)
  Given(:tape) { NittyMail::IMAPTape.new(cassette_path) }
  Given(:reporter) { CollectingReporter.new }
  Given(:db_copy) do
    src = File.expand_path("../data/query_given.sqlite3", __dir__)
    dest = File.expand_path("../data/test_integration.sqlite3", __dir__)
    FileUtils.cp(src, dest)
    dest
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

    Then { reporter.events.map(&:first).include?(:mailbox_summary) }
  end

  context "record to cassette" do
    Given do
      skip("recording disabled; set INTEGRATION_RECORD=1 to enable") unless ENV["INTEGRATION_RECORD"]

      # Wrap live calls and record to tape
      orig_compute = NittyMail::Preflight.method(:compute)
      allow(NittyMail::Preflight).to receive(:compute) do |imap, email_ds, mbox_name, db_mutex|
        res = orig_compute.call(imap, email_ds, mbox_name, db_mutex)
        tape.record_preflight(mbox_name, res)
        res
      end

      allow_any_instance_of(NittyMail::IMAPClient).to receive(:fetch_with_retry).and_wrap_original do |m, *args, **kwargs|
        res = m.call(*args, **kwargs)
        # Serialize attrs for tape (record full bodies by default)
        serial = res.map { |fd| {"attr" => fd.attr.dup} }
        tape.record_fetch(kwargs[:mailbox_name], args.first, serial)
        res
      end
    end

    When do
      only_mbs = (ENV["ONLY_MAILBOXES"] && ENV["ONLY_MAILBOXES"].split(",").map(&:strip)) || ["INBOX"]
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
