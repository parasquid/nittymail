# frozen_string_literal: true

require "active_job"
require "fileutils"
require "nitty_mail"
require "time"

# Fetch a batch of UIDs and write raw RFC822 artifacts to archive directory
class ArchiveFetchJob < ActiveJob::Base
  queue_as :fetch

  # args:
  # - address, password, mailbox, uidvalidity
  # - uids: array of Integers
  # - settings: optional hash for NittyMail::Settings overrides
  # - archive_dir: optional base dir for outputs
  def perform(address:, password:, mailbox:, uidvalidity:, uids:, settings: {}, archive_dir: nil, run_id: nil, strict: false)
    return if run_id && aborted?(run_id)

    settings_args = {imap_address: address, imap_password: password}.merge(settings || {})
    settings_obj = NittyMail::Settings.new(**settings_args)
    mailbox_client = NittyMail::Mailbox.new(settings: settings_obj, mailbox_name: mailbox)

    base_dir = archive_dir || File.expand_path("../archives", __dir__)
    safe_address = address.to_s.downcase
    safe_mailbox = NittyMail::Utils.sanitize_collection_name(mailbox.to_s)
    uv_dir = File.join(base_dir, safe_address, safe_mailbox, uidvalidity.to_s)
    FileUtils.mkdir_p(uv_dir)

    begin
      fetch_response = mailbox_client.fetch(uids: Array(uids))
      fetch_response.each do |msg|
        break if run_id && aborted?(run_id)
        uid = msg.attr["UID"] || msg.attr[:UID] || msg.attr[:uid]
        final = File.join(uv_dir, "#{uid}.eml")
        if File.exist?(final)
          increment_counter(run_id, :processed)
          next
        end
        raw = msg.attr["BODY[]"] || msg.attr["BODY"] || msg.attr[:BODY] || msg.attr[:"BODY[]"]
        raw = raw.to_s.dup
        raw.force_encoding("BINARY")

        tmp = File.join(uv_dir, ".#{uid}.eml.tmp")
        File.binwrite(tmp, raw)
        File.rename(tmp, final)
        increment_counter(run_id, :processed)
      rescue => e
        warn "archive fetch job error: #{e.class}: #{e.message} addr=#{address} mb=#{mailbox} uv=#{uidvalidity}"
        if strict || ENV["NITTYMAIL_STRICT"] == "1"
          raise
        else
          increment_counter(run_id, :errors)
          # cleanup tmp if exists
          begin
            File.delete(tmp) if tmp && File.exist?(tmp)
          rescue
          end
        end
      end
    ensure
      begin
        mailbox_client&.logout if mailbox_client&.respond_to?(:logout)
      rescue
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
      r.incr("nm:arc:#{run_id}:#{key}")
    rescue
    end
  end

  def aborted?(run_id)
    require "redis"
    url = ENV["REDIS_URL"] || "redis://redis:6379/0"
    r = ::Redis.new(url: url)
    r.get("nm:arc:#{run_id}:aborted").to_s == "1"
  rescue
    false
  end
end
