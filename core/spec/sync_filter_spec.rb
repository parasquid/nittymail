# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "ostruct"

require_relative "../sync"

RSpec.describe NittyMail::Sync, "mailbox filters" do
  before do
    # Stub Mail.connection to yield a fake imap that returns our mailbox list
    @mailboxes = [
      OpenStruct.new(name: "INBOX", attr: []),
      OpenStruct.new(name: "[Gmail]/All Mail", attr: []),
      OpenStruct.new(name: "Spam", attr: [])
    ]

    allow(Mail).to receive(:connection).and_yield(double("imap", list: @mailboxes))

    # Stub Net::IMAP used in preflight workers
    fake_imap = double("net-imap", login: true, logout: true, disconnect: true)
    allow(Net::IMAP).to receive(:new).and_return(fake_imap)

    # Stub preflight compute to avoid real IMAP ops
    allow(NittyMail::Preflight).to receive(:compute).and_return(
      {uidvalidity: 1, to_fetch: [1], db_only: [], server_size: 1, db_size: 0}
    )

    # Capture mailbox runner invocations
    @runner_calls = []
    allow(NittyMail::MailboxRunner).to receive(:run) do |args|
      @runner_calls << args
      :ok
    end
  end

  let(:db_path) { File.expand_path("../data/query_given.sqlite3", __dir__) }

  it "processes only included mailbox when --only matches one" do
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

    expect(@runner_calls.length).to eq(1)
    expect(@runner_calls.first[:mbox_name]).to eq("[Gmail]/All Mail")
  end

  it "processes multiple included mailboxes when array provided" do
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

    names = @runner_calls.map { |c| c[:mbox_name] }
    expect(names).to contain_exactly("INBOX", "[Gmail]/All Mail")
  end

  it "processes nothing when --only matches zero" do
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

    expect(@runner_calls.length).to eq(0)
  end

  it "applies ignore after include (included can still be ignored)" do
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

    expect(@runner_calls.length).to eq(0)
  end
end
