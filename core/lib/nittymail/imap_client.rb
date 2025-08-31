# frozen_string_literal: true

require "net/imap"
require_relative "gmail_patch"

module NittyMail
  class IMAPClient
    def initialize(address:, password:)
      @address = address
      @password = password
      @imap = nil
    end

    def close
      if @imap
        begin
          @imap.logout
          @imap.disconnect
        rescue => e
          # Log the exception but don't let it crash the cleanup process
          warn "Warning: Exception during IMAP cleanup: #{e.class}: #{e.message}"
        end
        @imap = nil
      end
    end

    def reconnect_and_select(mailbox_name, expected_uidvalidity = nil)
      close
      @imap = Net::IMAP.new("imap.gmail.com", port: 993, ssl: true)
      @imap.login(@address, @password)
      @imap.examine(mailbox_name)
      GmailPatch.apply(@imap)
      uidv = @imap.responses["UIDVALIDITY"]&.first
      raise "UIDVALIDITY missing for mailbox #{mailbox_name} in worker" if uidv.nil?
      if expected_uidvalidity && uidv.to_i != expected_uidvalidity.to_i
        raise "UIDVALIDITY changed for mailbox #{mailbox_name} (preflight=#{expected_uidvalidity}, worker=#{uidv}). Please rerun."
      end
      @imap
    end

    def fetch_with_retry(batch, fetch_items, mailbox_name:, expected_uidvalidity:, retry_attempts:, progress: nil)
      attempts = 0
      loop do
        attempts += 1
        begin
          return @imap.uid_fetch(batch, fetch_items) || []
        rescue OpenSSL::SSL::SSLError, IOError, Errno::ECONNRESET => e
          progress&.log("IMAP read error (#{e.class}: #{e.message}) on #{mailbox_name}; retrying (attempt #{attempts})...")
          if retry_attempts == -1 || attempts < retry_attempts
            sleep 1 * attempts
            reconnect_and_select(mailbox_name, expected_uidvalidity)
          else
            raise e
          end
        end
      end
    end
  end
end
