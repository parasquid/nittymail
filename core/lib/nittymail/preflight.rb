# frozen_string_literal: true

module NittyMail
  module Preflight
    module_function

    def compute(imap, email_dataset, mailbox_name, db_mutex)
      imap.examine(mailbox_name)
      uidvalidity = imap.responses["UIDVALIDITY"]&.first
      raise "UIDVALIDITY missing for mailbox #{mailbox_name}" if uidvalidity.nil?

      server_uids = imap.uid_search("UID 1:*")
      db_uids = db_mutex.synchronize do
        email_dataset.where(mailbox: mailbox_name, uidvalidity: uidvalidity).select_map(:uid)
      end
      to_fetch = server_uids - db_uids
      db_only = db_uids - server_uids
      {
        uidvalidity: uidvalidity,
        to_fetch: to_fetch,
        db_only: db_only,
        server_size: server_uids.size,
        db_size: db_uids.size
      }
    end
  end
end
