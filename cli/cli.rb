#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "thor"
require "nitty_mail"

module NittyMail
  class CLI < Thor
    # Subcommand: mailbox
    class MailboxCmd < Thor
      desc "list", "List all mailboxes for the account"
      method_option :address, aliases: "-a", type: :string, required: true, desc: "IMAP account (email)"
      method_option :password, aliases: "-p", type: :string, required: true, desc: "IMAP password / app password"
      def list
        settings = NittyMail::Settings.new(
          imap_address: options[:address],
          imap_password: options[:password]
        )
        mb = NittyMail::Mailbox.new(settings: settings)
        list = Array(mb.list)

        names = list.map { |x| x.respond_to?(:name) ? x.name : x.to_s }

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
      rescue StandardError => e
        warn "unexpected error: #{e.class}: #{e.message}"
        exit 3
      end
    end

    desc "mailbox SUBCOMMAND ...ARGS", "Mailbox commands"
    subcommand "mailbox", MailboxCmd
  end
end

if $PROGRAM_NAME == __FILE__
  NittyMail::CLI.start(ARGV)
end
