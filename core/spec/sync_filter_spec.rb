# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "ostruct"

require_relative "../sync"

RSpec.describe NittyMail::Sync, "mailbox filters" do
  Given(:mailboxes) do
    [
      OpenStruct.new(name: "INBOX", attr: []),
      OpenStruct.new(name: "[Gmail]/All Mail", attr: []),
      OpenStruct.new(name: "Spam", attr: [])
    ]
  end

  Given do
    allow(Mail).to receive(:connection).and_yield(double("imap", list: mailboxes))
    fake_imap = double("net-imap", login: true, logout: true, disconnect: true)
    allow(Net::IMAP).to receive(:new).and_return(fake_imap)
    allow(NittyMail::Preflight).to receive(:compute).and_return({uidvalidity: 1, to_fetch: [1], db_only: [], server_size: 1, db_size: 0})
  end

  Given(:runner_calls) { [] }
  Given do
    allow(NittyMail::MailboxRunner).to receive(:run) do |args|
      runner_calls << args
      :ok
    end
  end

  Given(:db_path) { File.expand_path("../data/query_given.sqlite3", __dir__) }

  context "with only one included mailbox" do
    When do
      described_class.perform(
        imap_address: "test@example.com",
        imap_password: "pw",
        database_path: db_path,
        threads_count: 1,
        mailbox_threads: 1,
        auto_confirm: true,
        only_mailboxes: ["[Gmail]/All Mail"],
        ignore_mailboxes: []
      )
    end
    Then { runner_calls.length == 1 }
    Then { runner_calls.first[:mbox_name] == "[Gmail]/All Mail" }
  end

  context "with multiple included mailboxes" do
    When do
      described_class.perform(
        imap_address: "test@example.com",
        imap_password: "pw",
        database_path: db_path,
        threads_count: 1,
        mailbox_threads: 1,
        auto_confirm: true,
        only_mailboxes: ["INBOX", "[Gmail]/All Mail"],
        ignore_mailboxes: []
      )
    end
    Then do
      names = runner_calls.map { |c| c[:mbox_name] }
      expect(names).to contain_exactly("INBOX", "[Gmail]/All Mail")
    end
  end

  context "when only matches zero" do
    When do
      described_class.perform(
        imap_address: "test@example.com",
        imap_password: "pw",
        database_path: db_path,
        threads_count: 1,
        mailbox_threads: 1,
        auto_confirm: true,
        only_mailboxes: ["DoesNotExist"],
        ignore_mailboxes: []
      )
    end
    Then { runner_calls.length == 0 }
  end

  context "ignore after include" do
    When do
      described_class.perform(
        imap_address: "test@example.com",
        imap_password: "pw",
        database_path: db_path,
        threads_count: 1,
        mailbox_threads: 1,
        auto_confirm: true,
        only_mailboxes: ["[Gmail]/All Mail"],
        ignore_mailboxes: ["[Gmail]/*"]
      )
    end
    Then { runner_calls.length == 0 }
  end
end
