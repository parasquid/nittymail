require_relative "../lib/nittymail/util"
require_relative "spec_helper"
require "mail"

RSpec.describe NittyMail::Util do
  describe ".safe_utf8" do
    it "removes invalid bytes and returns UTF-8 (keeps valid bytes)" do
      bad = "\xC3\x28".force_encoding("binary")
      out = described_class.safe_utf8(bad)
      expect(out.encoding).to eq(Encoding::UTF_8)
      expect(out).to eq("(")
    end

    it "handles frozen empty strings" do
      out = described_class.safe_utf8("")
      expect(out).to eq("")
      expect(out.frozen?).to be false
    end
  end

  describe ".extract_subject" do
    it "returns subject from Mail when available" do
      m = Mail.new
      m.subject = "Hello"
      expect(described_class.extract_subject(m, "")).to eq("Hello")
    end

    it "falls back to raw headers when Mail subject access raises" do
      mail = double("Mail", subject: nil)
      allow(mail).to receive(:subject).and_raise(ArgumentError)
      raw = "Subject: Test Subject\r\nFrom: a@b\r\n\r\nBody"
      expect(described_class.extract_subject(mail, raw)).to eq("Test Subject")
    end
  end
end
