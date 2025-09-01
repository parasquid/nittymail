# frozen_string_literal: true

require "spec_helper"
require "ostruct"

require_relative "../lib/nittymail/reporter"
require_relative "../lib/nittymail/db"
require_relative "../lib/nittymail/sync_utils"

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

RSpec.describe NittyMail::SyncUtils do
  context "filters" do
    Given(:mailboxes) do
      [
        OpenStruct.new(name: "INBOX", attr: []),
        OpenStruct.new(name: "[Gmail]/All Mail", attr: []),
        OpenStruct.new(name: "Spam", attr: [])
      ]
    end

    Then "only filter keeps matches" do
      kept = described_class.filter_mailboxes_by_only_list(mailboxes, ["INBOX", "[Gmail]/All Mail"])
      expect(kept.map(&:name)).to contain_exactly("INBOX", "[Gmail]/All Mail")
    end

    Then "ignore filter drops matches" do
      kept = described_class.filter_mailboxes_by_ignore_list(mailboxes, ["Spam"])
      expect(kept.map(&:name)).to contain_exactly("INBOX", "[Gmail]/All Mail")
    end
  end

  context "prune logic" do
    Given(:db) do
      dbl = double("db")
      allow(dbl).to receive(:transaction).and_yield
      dbl
    end
    Given(:reporter) { CollectingReporter.new }

    When(:result) do
      allow(NittyMail::DB).to receive(:prune_missing!).and_return(3)
      described_class.handle_prune_missing(db, true, :ok, "INBOX", 1, [1, 2, 3], reporter)
    end
    Then { result == 3 }
    Then do
      evt = reporter.events.find { |(t, _)| t == :pruned_missing }
      expect(evt).not_to be_nil
      expect(evt.last[:pruned]).to eq(3)
    end

    Then "skips on aborted" do
      rep = CollectingReporter.new
      r = described_class.handle_prune_missing(db, true, :aborted, "INBOX", 1, [1], rep)
      expect(r).to eq(0)
      expect(rep.events.map(&:first)).to include(:prune_skipped_due_to_abort)
    end

    Then "reports candidates when disabled" do
      rep = CollectingReporter.new
      r = described_class.handle_prune_missing(db, false, :ok, "INBOX", 1, [1, 2], rep)
      expect(r).to eq(0)
      expect(rep.events.map(&:first)).to include(:prune_candidates_present)
    end
  end

  context "purge old validity" do
    Given(:db) { double("db") }
    Given(:reporter) { CollectingReporter.new }
    Given(:settings) { OpenStruct.new(purge_old_validity: true, auto_confirm: true) }
    Given(:email_ds) { double("email_ds") }

    Given do
      chain = double("chain")
      allow(email_ds).to receive(:where).with(mailbox: "INBOX").and_return(chain)
      allow(chain).to receive(:exclude).with(uidvalidity: 1).and_return(chain)
      allow(chain).to receive(:distinct).and_return(chain)
      allow(chain).to receive(:select_map).with(:uidvalidity).and_return([2])
      allow(chain).to receive(:count).and_return(5)
      allow(chain).to receive(:delete).and_return(5)
      allow(db).to receive(:transaction).and_yield
    end

    When(:count) { described_class.handle_purge_old_validity(db, email_ds, settings, "INBOX", 1, reporter, stdin: double("stdin", tty?: false)) }
    Then { count == 5 }
    Then { reporter.events.map(&:first).include?(:purge_old_validity) }

    Then "skips when no other validities" do
      chain = double("chain")
      allow(email_ds).to receive(:where).with(mailbox: "INBOX").and_return(chain)
      allow(chain).to receive(:exclude).with(uidvalidity: 1).and_return(chain)
      allow(chain).to receive(:distinct).and_return(chain)
      allow(chain).to receive(:select_map).with(:uidvalidity).and_return([])
      c = described_class.handle_purge_old_validity(db, email_ds, settings, "INBOX", 1, reporter, stdin: double("stdin", tty?: false))
      expect(c).to eq(0)
    end
  end
end
