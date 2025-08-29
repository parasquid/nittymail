require_relative "../lib/nittymail/preflight"
require_relative "spec_helper"

class FakeIMAP
  attr_reader :responses

  def initialize(uidvalidity:, server_uids: [])
    @uidvalidity = uidvalidity
    @server_uids = server_uids
    @responses = {}
  end

  def examine(_mailbox)
    @responses["UIDVALIDITY"] = [@uidvalidity]
  end

  def uid_search(_query)
    @server_uids
  end
end

class FakeDataset
  def initialize(db_map)
    @db_map = db_map
  end

  def where(mailbox:, uidvalidity:)
    @last_key = [mailbox, uidvalidity]
    self
  end

  def select_map(_column)
    @db_map.fetch(@last_key, [])
  end
end

RSpec.describe NittyMail::Preflight do
  context "diff computation" do
    Given(:uidvalidity) { 123 }
    Given(:server_uids) { [1, 2, 3] }
    Given(:db_uids) { [2, 99] }
    Given(:imap) { FakeIMAP.new(uidvalidity: uidvalidity, server_uids: server_uids) }
    Given(:email_ds) { FakeDataset.new({["INBOX", uidvalidity] => db_uids}) }
    Given(:mutex) { Mutex.new }
    When(:res) { NittyMail::Preflight.compute(imap, email_ds, "INBOX", mutex) }
    Then { expect(res[:uidvalidity]).to eq(uidvalidity) }
    Then { expect(res[:to_fetch]).to eq([1, 3]) }
    Then { expect(res[:db_only]).to eq([99]) }
    Then { expect(res[:server_size]).to eq(3) }
    Then { expect(res[:db_size]).to eq(2) }
  end
end
