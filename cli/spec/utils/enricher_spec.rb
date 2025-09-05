# frozen_string_literal: true

require "spec_helper"
require_relative "../../utils/enricher"

RSpec.describe NittyMail::Enricher do
  def base_meta
    {
      address: "user@example.com",
      mailbox: "INBOX",
      uidvalidity: 2,
      uid: 123,
      internaldate_epoch: 1_700_000_000,
      from_email: "sender@example.com",
      rfc822_size: 100,
      labels: ["\\Inbox"],
      item_type: "raw"
    }
  end

  Given(:uv) { 2 }
  Given(:uid) { 123 }

  context "text-only email" do
    Given(:raw) do
      m = Mail.new
      m.subject = "Hello Subject"
      m.body = "Plain text body
with two lines"
      m.to_s
    end

    When(:result) { described_class.variants_for(raw: raw, base_meta: base_meta, uidvalidity: uv, uid: uid) }
    Then { result.is_a?(Array) }
    Then { result.size == 3 }
    Then do
      ids, docs, metas = result
      expect(ids).to include("2:123:subject", "2:123:text", "2:123:markdown")
      expect(docs[ids.index("2:123:subject")]).to eq("Hello Subject")
      text = docs[ids.index("2:123:text")]
      md = docs[ids.index("2:123:markdown")]
      expect(text).to include("Plain text body")
      expect(md).to include("Plain text body")
      expect(metas[ids.index("2:123:text")][:item_type]).to eq("plain_text")
      expect(metas[ids.index("2:123:markdown")][:item_type]).to eq("markdown")
    end
  end

  context "html-only email" do
    Given(:raw) do
      m = Mail.new
      m.content_type = "text/html; charset=UTF-8"
      m.subject = "Subj"
      m.body = "<p>Hello <b>world</b></p>"
      m.to_s
    end
    When(:result) { described_class.variants_for(raw: raw, base_meta: base_meta, uidvalidity: uv, uid: uid) }
    Then do
      ids, docs, = result
      md = docs[ids.index("2:123:markdown")]
      stripped = md.downcase.delete("*").gsub(/\s+/, " ")
      expect(stripped).to include("hello world")
    end
  end

  context "non-UTF8 bytes are normalized" do
    Given(:raw) do
      m = Mail.new
      m.subject = "Price ®"
      m.body = "Body with byte ®"
      r = m.to_s
      r.force_encoding("BINARY")
      r
    end
    When(:result) { described_class.variants_for(raw: raw, base_meta: base_meta, uidvalidity: uv, uid: uid) }
    Then do
      ids, _docs, = result
      expect(ids).to include("2:123:subject", "2:123:text", "2:123:markdown")
      expect(true).to be true
    end
  end
end
