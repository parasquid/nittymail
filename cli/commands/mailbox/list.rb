# frozen_string_literal: true

require "thor"
require "nitty_mail"

module NittyMail
  module Commands
    class MailboxList < Thor
        desc "list", "List all mailboxes for the account"
        method_option :address, aliases: "-a", type: :string, required: false, desc: "IMAP account (email) (or env NITTYMAIL_IMAP_ADDRESS)"
        method_option :password, aliases: "-p", type: :string, required: false, desc: "IMAP password / app password (or env NITTYMAIL_IMAP_PASSWORD)"
        def list
          address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
          password = options[:password] || ENV["NITTYMAIL_IMAP_PASSWORD"]

          if address.to_s.empty? || password.to_s.empty?
            raise ArgumentError, "missing credentials: pass --address/--password or set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD"
          end

          settings = NittyMail::Settings.new(imap_address: address, imap_password: password)
          mailbox_client = NittyMail::Mailbox.new(settings: settings)
          mailboxes = Array(mailbox_client.list)
          begin
            if mailbox_client.respond_to?(:close)
              mailbox_client.close
            elsif mailbox_client.respond_to?(:disconnect)
              mailbox_client.disconnect
            elsif mailbox_client.respond_to?(:logout)
              mailbox_client.logout
            end
          rescue
          end

          names = mailboxes.map { |x| x.respond_to?(:name) ? x.name : x.to_s }
          if names.empty?
            puts "(no mailboxes)"
          else
            names.sort.each { |n| puts n }
          end
        rescue ArgumentError => e
          warn "error: #{e.message}"
          exit 1
        rescue Net::IMAP::NoResponseError, Net::IMAP::BadResponseError => e
          warn "imap error: #{e.message}"
          exit 2
        rescue => e
          warn "unexpected error: #{e.class}: #{e.message}"
          exit 3
        end
    end
  end
end