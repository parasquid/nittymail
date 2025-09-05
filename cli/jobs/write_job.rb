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
  def perform(address:, mailbox:, uidvalidity:, uid:, artifact_path:, internaldate_epoch:, from_email: nil, rfc822_size: nil, labels: [], run_id: nil, strict: false, sha256: nil)
    # Respect abort flag if present; leave artifact for cleanup
    if run_id && aborted?(run_id)
      return
    end
    raw = File.binread(artifact_path)
    raw.force_encoding("BINARY")
    keep_artifact = false

    begin
      if sha256 && !sha256.to_s.empty?
        require "digest"
        computed = Digest::SHA256.hexdigest(raw)
        if computed != sha256
          warn "write checksum mismatch: uv=#{uidvalidity} uid=#{uid}"
          increment_counter(run_id, :errors) if run_id
          keep_artifact = true # keep for inspection
          return
        end
      end
    rescue => e
      warn "write checksum error: #{e.class}: #{e.message} uv=#{uidvalidity} uid=#{uid}"
      if strict || ENV["NITTYMAIL_STRICT"] == "1"
        raise
      else
        increment_counter(run_id, :errors) if run_id
        return
      end
    end

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
      if strict || ENV["NITTYMAIL_STRICT"] == "1"
        raise
      else
        increment_counter(run_id, :errors) if run_id
        return
      end
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
      if strict || ENV["NITTYMAIL_STRICT"] == "1"
        raise
      elsif run_id
        increment_counter(run_id, :errors)
      end
    ensure
      begin
        File.delete(artifact_path) if !keep_artifact && File.exist?(artifact_path)
      rescue
      end
    end
    increment_counter(run_id, :processed) if run_id
  end

  private

  def increment_counter(run_id, key)
    return unless run_id
    begin
      require "redis"
      url = ENV["REDIS_URL"] || "redis://redis:6379/0"
      r = ::Redis.new(url: url)
      r.incr("nm:dl:#{run_id}:#{key}")
    rescue
    end
  end

  def aborted?(run_id)
    require "redis"
    url = ENV["REDIS_URL"] || "redis://redis:6379/0"
    r = ::Redis.new(url: url)
    r.get("nm:dl:#{run_id}:aborted").to_s == "1"
  rescue
    false
  end
end
