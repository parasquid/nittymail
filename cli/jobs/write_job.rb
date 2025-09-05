# frozen_string_literal: true

require "active_job"
require "fileutils"
require "json"
require_relative "../utils/enricher"
require_relative "../models/email"

class WriteJob < ActiveJob::Base
  queue_as :write

  # args:
  # - address, mailbox, uidvalidity, uid
  # - artifact_path: String
  # - internaldate_epoch: Integer
  # - from_email: String (optional)
  # - rfc822_size: Integer (optional)
  # - labels: Array<String>
  def perform(address:, mailbox:, uidvalidity:, uid:, artifact_path:, internaldate_epoch:, from_email: nil, rfc822_size: nil, labels: [])
    raw = File.binread(artifact_path)
    raw.force_encoding("BINARY")

    subject = ""
    plain_text = ""
    markdown = ""
    to_emails = nil
    cc_emails = nil
    bcc_emails = nil
    begin
      mail = ::Mail.read_from_string(NittyMail::Enricher.normalize_utf8(raw))
      subject = NittyMail::Enricher.normalize_utf8(mail.subject.to_s)
      text_part = NittyMail::Enricher.safe_decode(mail.text_part)
      html_part = NittyMail::Enricher.safe_decode(mail.html_part)
      body_fallback = NittyMail::Enricher.safe_decode(mail.body)
      plain_text = NittyMail::Enricher.normalize_utf8(text_part.to_s.strip.empty? ? body_fallback.to_s : text_part.to_s)
      markdown = if html_part && !html_part.to_s.strip.empty?
        ::ReverseMarkdown.convert(html_part.to_s)
      else
        ::ReverseMarkdown.convert(plain_text.to_s)
      end
      markdown = NittyMail::Enricher.normalize_utf8(markdown)

      to_list = Array(mail.to).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
      cc_list = Array(mail.cc).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
      bcc_list = Array(mail.bcc).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
      to_emails = JSON.generate(to_list) unless to_list.empty?
      cc_emails = JSON.generate(cc_list) unless cc_list.empty?
      bcc_emails = JSON.generate(bcc_list) unless bcc_list.empty?
    rescue => e
      warn "write parse error: #{e.class}: #{e.message} uv=#{uidvalidity} uid=#{uid}"
      raise if ENV["NITTYMAIL_STRICT"] == "1"
    end

    begin
      NittyMail::Email.upsert_all([
        {
          address: address,
          mailbox: mailbox,
          uidvalidity: uidvalidity,
          uid: uid,
          subject: subject,
          internaldate: Time.at(internaldate_epoch),
          internaldate_epoch: internaldate_epoch,
          rfc822_size: rfc822_size,
          from_email: from_email,
          labels_json: JSON.generate(Array(labels)),
          to_emails: to_emails,
          cc_emails: cc_emails,
          bcc_emails: bcc_emails,
          raw: raw,
          plain_text: plain_text,
          markdown: markdown,
          created_at: Time.now,
          updated_at: Time.now
        }
      ], unique_by: "index_emails_on_identity")
    rescue => e
      warn "write db error: #{e.class}: #{e.message} uv=#{uidvalidity} uid=#{uid}"
      raise if ENV["NITTYMAIL_STRICT"] == "1"
    ensure
      begin
        File.delete(artifact_path) if File.exist?(artifact_path)
      rescue
      end
    end
  end
end
