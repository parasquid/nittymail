require "net/imap"

module NittyMail
  class Mailbox
    def initialize(settings:, mailbox_name: "INBOX")
      @mailbox_name = mailbox_name
      @settings = settings
    end

    def preflight(existing_uids: [])
      with_imap do |imap|
        uidvalidity = imap.responses["UIDVALIDITY"]&.first
        raise NittyMail::MissingUIDValidityError.new(@mailbox_name) if uidvalidity.nil?

        server_uids = imap.uid_search("UID 1:*")
        to_fetch = server_uids - existing_uids

        {
          capabilities: imap.capabilities,
          uidvalidity:,
          server_size: server_uids.size,
          to_fetch:
        }
      end
    end

    def retrieve(uids:, extra_fetch_items: ["X-GM-LABELS", "X-GM-MSGID", "X-GM-THRID"])
      raise NittyMail::MaxFetchSizeError.new(uids.size, @settings.max_fetch_size) if uids.size > @settings.max_fetch_size

      with_imap do |imap|
        imap.uid_fetch(uids, @settings.fetch_items + extra_fetch_items)
      end
    end

    private

    def with_imap(&block)
      imap = Net::IMAP.new(@settings.imap_url, port: @settings.imap_port, ssl: @settings.imap_ssl)
      imap.login(@settings.imap_address, @settings.imap_password)
      imap.examine(@mailbox_name)

      yield imap
    ensure
      imap.logout
      imap.disconnect
    end
  end
end
