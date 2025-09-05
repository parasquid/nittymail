# frozen_string_literal: true

require "active_job"
require "fileutils"
require "json"
require "time"
require "nitty_mail"
require "digest"

# Fetch a batch of UIDs, write raw artifacts to disk, and enqueue write jobs
class FetchJob < ActiveJob::Base
  queue_as :fetch

  # args:
  # - address, password, mailbox, uidvalidity
  # - uids: array of Integers
  # - settings: optional hash for NittyMail::Settings overrides
  # - artifact_dir: optional base dir for artifacts
  def perform(address:, password:, mailbox:, uidvalidity:, uids:, settings: {}, artifact_dir: nil, run_id: nil, strict: false)
    # Add small delay when using ActiveJob TestAdapter to allow interrupt trap to set abort flag
    begin
      aj_adapter = ActiveJob::Base.queue_adapter
      if aj_adapter && aj_adapter.class.name =~ /TestAdapter/i
        sleep 0.5
      end
    rescue
    end
    # Respect abort flag if present
    if run_id && aborted?(run_id)
      return
    end
    settings_args = {imap_address: address, imap_password: password}.merge(settings || {})
    settings_obj = NittyMail::Settings.new(**settings_args)
    mailbox_client = NittyMail::Mailbox.new(settings: settings_obj, mailbox_name: mailbox)

    base_dir = artifact_dir || File.expand_path("../job-data", __dir__)
    safe_address = address.to_s.downcase
    safe_mailbox = NittyMail::Utils.sanitize_collection_name(mailbox.to_s)
    root = File.join(base_dir, safe_address, safe_mailbox, uidvalidity.to_s)
    FileUtils.mkdir_p(root)

    begin
      fetch_response = mailbox_client.fetch(uids: Array(uids))
      fetch_response.each do |msg|
        # re-check abort between messages to exit early if requested
        if run_id && aborted?(run_id)
          break
        end
        uid = msg.attr["UID"] || msg.attr[:UID] || msg.attr[:uid]
        raw = msg.attr["BODY[]"] || msg.attr["BODY"] || msg.attr[:BODY] || msg.attr[:"BODY[]"]
        raw = raw.to_s.dup
        raw.force_encoding("BINARY")

        internal = msg.attr["INTERNALDATE"] || msg.attr[:INTERNALDATE] || msg.attr[:internaldate]
        internal_time = internal.is_a?(Time) ? internal : (begin
          Time.parse(internal.to_s)
        rescue
          Time.at(0)
        end)
        internal_epoch = internal_time.to_i

        envelope = msg.attr["ENVELOPE"] || msg.attr[:ENVELOPE] || msg.attr[:envelope]
        from_email = begin
          addrs = envelope&.from
          addr = Array(addrs).first
          m = addr&.mailbox&.to_s
          h = addr&.host&.to_s
          (m && h && !m.empty? && !h.empty?) ? "#{m}@#{h}".downcase : nil
        rescue
          nil
        end

        labels_attr = msg.attr["X-GM-LABELS"] || msg.attr[:"X-GM-LABELS"] || msg.attr[:x_gm_labels]
        labels = Array(labels_attr).map { |v| v.to_s }

        size_attr = msg.attr["RFC822.SIZE"] || msg.attr[:"RFC822.SIZE"]
        rfc822_size = size_attr.to_i

        # Write atomically
        tmp = File.join(root, ".#{uid}.eml.tmp")
        final = File.join(root, "#{uid}.eml")
        File.binwrite(tmp, raw)
        File.rename(tmp, final)

        sha256 = Digest::SHA256.hexdigest(raw)

        WriteJob.perform_later(
          address: address,
          mailbox: mailbox,
          uidvalidity: uidvalidity,
          uid: uid,
          artifact_path: final,
          sha256: sha256,
          internaldate_epoch: internal_epoch,
          from_email: from_email,
          rfc822_size: rfc822_size,
          labels: labels,
          run_id: run_id,
          strict: strict
        )
      end
    rescue => e
      warn "fetch job error: #{e.class}: #{e.message} addr=#{address} mb=#{mailbox} uv=#{uidvalidity} uids=#{uids.first}..#{uids.last}"
      raise if strict || ENV["NITTYMAIL_STRICT"] == "1"
    ensure
      begin
        mailbox_client&.logout if mailbox_client&.respond_to?(:logout)
      rescue
      end
    end
  end

  private

  def aborted?(run_id)
    require "redis"
    url = ENV["REDIS_URL"] || "redis://redis:6379/0"
    r = ::Redis.new(url: url)
    r.get("nm:dl:#{run_id}:aborted").to_s == "1"
  rescue
    false
  end
end
