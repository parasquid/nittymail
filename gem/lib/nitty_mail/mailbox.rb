# frozen_string_literal: true

require "net/imap"

module NittyMail
  class Mailbox
    def initialize(settings: Settings.new, mailbox_name: "INBOX")
      @mailbox_name = mailbox_name
      @settings = settings
    end

    def list
      with_imap do |imap|
        imap.list("", "*")
      end
    end

    # Preflight a mailbox to plan an efficient sync.
    #
    # Enumerate the server-side UID set, and compute the difference against
    # `existing_uids` to determine exactly which messages are missing locally.
    #
    # Purpose:
    # - Fail fast if UIDVALIDITY is missing so the caller can handle the
    #   mailbox as unsupported.
    # - Avoid fetching already-synced messages by returning an explicit
    #   `to_fetch` UID list.
    # - Provide small but useful telemetry (capabilities, sizes) for logging
    #   and progress reporting.
    #
    # @param existing_uids [Array<Integer>] UIDs already present in the local DB
    #   for this mailbox and current UIDVALIDITY generation.
    # @return [Hash] Summary data used by the sync planner.
    # @return [Hash] keys:
    #   - :capabilities [Array<String>] the server's capability list
    #   - :uidvalidity [Integer] UIDVALIDITY for the examined mailbox
    #   - :server_size [Integer] count of UIDs on the server
    #   - :to_fetch [Array<Integer>] UIDs present on the server but missing locally
    # @raise [NittyMail::MissingUIDValidityError] if the server doesn't expose
    #   UIDVALIDITY for the mailbox.
    # @example Compute UIDs to fetch
    #   settings = NittyMail::Settings.new(imap_address: "user@example.com", imap_password: "secret")
    #   mailbox  = NittyMail::Mailbox.new(settings: settings, mailbox_name: "INBOX")
    #   plan = mailbox.preflight(existing_uids: [1, 2, 3])
    #   plan[:to_fetch] #=> [4, 5, 6]
    def preflight(existing_uids: [])
      with_imap do |imap|
        uidvalidity = imap.responses["UIDVALIDITY"]&.first
        raise NittyMail::MissingUIDValidityError.new(@mailbox_name) if uidvalidity.nil?

        server_uids = imap.uid_search("UID 1:*")
        to_fetch = server_uids - existing_uids

        {
          capabilities: imap.capability,
          uidvalidity:,
          server_size: server_uids.size,
          to_fetch:
        }
      end
    end

    def fetch(uids:)
      raise NittyMail::MaxFetchSizeError.new(uids.size, @settings.max_fetch_size) if uids.size > @settings.max_fetch_size

      with_imap do |imap|
        imap.uid_fetch(uids, @settings.fetch_items)
      end
    end

    private

    def with_imap(&block)
      imap = Net::IMAP.new(@settings.imap_url, port: @settings.imap_port, ssl: @settings.imap_ssl)
      imap.login(@settings.imap_address, @settings.imap_password)
      imap.examine(@mailbox_name)

      yield imap
    ensure
      begin
        imap&.logout
      rescue StandardError
        # ignore logout errors during cleanup
      end
      begin
        imap&.disconnect
      rescue StandardError
        # ignore disconnect errors during cleanup
      end
    end
  end
end
