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
  def perform(address:, mailbox:, uidvalidity:, uid:, artifact_path:, internaldate_epoch:, from_email: nil, rfc822_size: nil, labels: [], run_id: nil, strict: false, sha256: nil, x_gm_thrid: nil, x_gm_msgid: nil)
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
    message_id = nil
    header_date = nil
    from_display = nil
    reply_to_emails = nil
    in_reply_to = nil
    references_list = nil
    has_attachments = false
    to_emails = nil
    cc_emails = nil
    bcc_emails = nil
    begin
      mail = ::Mail.read_from_string(NittyMail::Enricher.normalize_utf8(raw))
      subject = NittyMail::Enricher.normalize_utf8(mail.subject.to_s)
      message_id = NittyMail::Enricher.normalize_utf8(mail.message_id.to_s)
      begin
        header_date = mail.date&.to_time
      rescue
        header_date = nil
      end
      from_display = NittyMail::Enricher.normalize_utf8(mail[:from]&.to_s)
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
      has_attachments = mail.attachments && !mail.attachments.empty?

      to_list = Array(mail.to).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
      cc_list = Array(mail.cc).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
      bcc_list = Array(mail.bcc).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
      reply_to_list = Array(mail.reply_to).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
      in_reply_to = NittyMail::Enricher.normalize_utf8(mail.in_reply_to.to_s)
      references_vals = Array(mail.references).map { |x| NittyMail::Enricher.normalize_utf8(x.to_s) }
      to_emails = JSON.generate(to_list) unless to_list.empty?
      cc_emails = JSON.generate(cc_list) unless cc_list.empty?
      bcc_emails = JSON.generate(bcc_list) unless bcc_list.empty?
      reply_to_emails = JSON.generate(reply_to_list) unless reply_to_list.empty?
      references_list = JSON.generate(references_vals) unless references_vals.empty?
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
          date: header_date,
          rfc822_size: rfc822_size,
          from_email: from_email,
          from: from_display,
          labels_json: JSON.generate(Array(labels)),
          to_emails: to_emails,
          cc_emails: cc_emails,
          bcc_emails: bcc_emails,
          envelope_reply_to: reply_to_emails,
          envelope_in_reply_to: in_reply_to,
          envelope_references: references_list,
          message_id: message_id,
          x_gm_thrid: x_gm_thrid,
          x_gm_msgid: x_gm_msgid,
          has_attachments: has_attachments,
          raw: raw,
          plain_text: plain_text,
          markdown: markdown,
          created_at: Time.now,
          updated_at: Time.now
        }
      ], unique_by: "index_emails_on_identity")
      # Only delete artifact and increment processed counter on successful DB write
      # Re-check aborted flag to retain artifacts on single-interrupt scenarios
      begin
        retain = false
        if run_id
          begin
            retain = aborted?(run_id)
          rescue
            retain = false
          end
        end
        File.delete(artifact_path) if !keep_artifact && !retain && File.exist?(artifact_path)
      rescue
      end
      increment_counter(run_id, :processed) if run_id
    rescue => e
      warn "write db error: #{e.class}: #{e.message} uv=#{uidvalidity} uid=#{uid}"
      if strict || ENV["NITTYMAIL_STRICT"] == "1"
        raise
      elsif run_id
        increment_counter(run_id, :errors)
      end
    end
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
