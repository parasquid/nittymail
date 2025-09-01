# frozen_string_literal: true

# Copyright 2025 parasquid

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

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
