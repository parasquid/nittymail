# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "ostruct"

require_relative "../enrich"
require_relative "../embed"
require_relative "../sync"

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

RSpec.describe "Reporter events" do
  Given(:db_src) { File.expand_path("../data/query_given.sqlite3", __dir__) }
  Given(:db_copy) { File.expand_path("../data/test_events.sqlite3", __dir__) }

  Given do
    FileUtils.cp(db_src, db_copy)
  end

  after(:each) { FileUtils.rm_f(db_copy) }

  context "enrich" do
    Given(:rep) { CollectingReporter.new }
    Given do
      db = Sequel.sqlite(db_copy)
      db[:email].update(rfc822_size: nil)
      db.disconnect
    end
    When { NittyMail::Enrich.perform(database_path: db_copy, quiet: true, reporter: rep) }
    Then { rep.events.map(&:first).include?(:enrich_started) }
    Then { rep.events.map(&:first).include?(:enrich_finished) }
    Then { rep.events.map(&:first).count { |t| t == :enrich_progress } > 0 }
    Then do
      finished = rep.events.reverse.find { |(t, _)| t == :enrich_finished }
      expect(finished.last).to include(:processed, :total, :errors)
    end
  end

  context "sync mailbox summary" do
    Given(:rep) { CollectingReporter.new }
    Given do
      mailboxes = [OpenStruct.new(name: "INBOX", attr: [])]
      allow(Mail).to receive(:connection).and_yield(double("imap", list: mailboxes))
      fake_imap = double("net-imap", login: true, logout: true, disconnect: true)
      allow(Net::IMAP).to receive(:new).and_return(fake_imap)
      allow(NittyMail::Preflight).to receive(:compute).and_return({uidvalidity: 1, to_fetch: [1], db_only: [], server_size: 1, db_size: 0})
      allow(NittyMail::MailboxRunner).to receive(:run).and_return({status: :ok, processed: 1, errors: 0})
    end
    When do
      NittyMail::Sync.perform(
        imap_address: "test@example.com",
        imap_password: "pw",
        database_path: db_copy,
        threads_count: 1,
        mailbox_threads: 1,
        auto_confirm: true,
        only_mailboxes: ["INBOX"],
        reporter: rep
      )
    end
    Then do
      summaries = rep.events.select { |(t, _)| t == :mailbox_summary }
      expect(summaries.length).to eq(1)
      payload = summaries[0][1]
      expect(payload).to include(:total, :processed, :errors, :pruned, :purged, :prune_candidates, :result)
    end
  end

  context "embed" do
    Given do
      allow(NittyMail::Embeddings).to receive(:fetch_embedding).and_return([0.0, 0.1, 0.2, 0.3])
    end
    Given(:rep) { CollectingReporter.new }
    Given(:settings) do
      EmbedSettings::Settings.new(
        database_path: db_copy,
        ollama_host: "http://localhost:11434",
        model: "test-model",
        dimension: 4,
        item_types: ["subject"],
        address_filter: nil,
        limit: 2,
        offset: 0,
        quiet: true,
        threads_count: 1,
        retry_attempts: 1,
        batch_size: 10,
        regenerate: true,
        use_search_prompt: false,
        write_batch_size: 10,
        reporter: rep
      )
    end
    When { NittyMail::Embed.perform(settings) }
    Then do
      finished = rep.events.reverse.find { |(t, _)| t == :embed_finished }
      expect(finished).not_to be_nil
      expect(finished.last).to include(:processed, :total, :errors)
    end
  end
end
