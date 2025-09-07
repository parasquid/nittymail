# frozen_string_literal: true

require "thor"
require_relative "mailbox/list"
require_relative "mailbox/download"
require_relative "mailbox/archive"

module NittyMail
  module Commands
    class Mailbox < Thor
      desc "list SUBCOMMAND ...ARGS", "List mailboxes"
      subcommand "list", MailboxList

      desc "download SUBCOMMAND ...ARGS", "Download emails"
      subcommand "download", MailboxDownload

      desc "archive SUBCOMMAND ...ARGS", "Archive emails"
      subcommand "archive", MailboxArchive
    end
  end
end
