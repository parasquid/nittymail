require_relative "../lib/nittymail/imap_client"
require_relative "spec_helper"
require "openssl"

class FlakyIMAP
  def initialize(failures_before_success)
    @remaining = failures_before_success
  end

  def uid_fetch(_batch, _items)
    if @remaining > 0
      @remaining -= 1
      raise OpenSSL::SSL::SSLError, "eof"
    end
    [{attr: {"UID" => 1, "FLAGS" => [], "BODY[]" => "raw"}}]
  end
end

class TestIMAPClient < NittyMail::IMAPClient
  attr_reader :reconnects

  def initialize
    @reconnects = 0
    @imap = FlakyIMAP.new(0)
  end

  def set_flaky(n)
    @imap = FlakyIMAP.new(n)
  end

  def reconnect_and_select(_mbox, _uidv = nil)
    @reconnects += 1
  end
end

RSpec.describe NittyMail::IMAPClient do
  it "retries and eventually succeeds" do
    client = TestIMAPClient.new
    client.set_flaky(2)
    res = client.fetch_with_retry([1], ["BODY.PEEK[]"], mailbox_name: "INBOX", expected_uidvalidity: 1, retry_attempts: 3, progress: nil)
    expect(res).to be_a(Array)
    expect(client.reconnects).to be >= 2
  end

  it "raises after exhausting retries" do
    client = TestIMAPClient.new
    client.set_flaky(3)
    expect {
      client.fetch_with_retry([1], ["BODY.PEEK[]"], mailbox_name: "INBOX", expected_uidvalidity: 1, retry_attempts: 2, progress: nil)
    }.to raise_error(OpenSSL::SSL::SSLError)
  end
end
