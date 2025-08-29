# frozen_string_literal: true

module NittyMail
  module DB
    module_function

    def ensure_schema!(db)
      unless db.table_exists?(:email)
        db.create_table :email do
          primary_key :id
          String :address, index: true
          String :mailbox, index: true
          Bignum :uid, index: true, default: 0
          Integer :uidvalidity, index: true, default: 0

          String :message_id, index: true
          DateTime :date, index: true
          String :from, index: true
          String :subject

          Boolean :has_attachments, index: true, default: false

          String :x_gm_labels
          String :x_gm_msgid
          String :x_gm_thrid
          String :flags

          String :encoded

          unique %i[mailbox uid uidvalidity]
          index %i[mailbox uidvalidity]
        end
      end
      db[:email]
    end

    def prepared_insert(email_dataset)
      email_dataset.prepare(
        :insert, :insert_email,
        address: :$address,
        mailbox: :$mailbox,
        uid: :$uid,
        uidvalidity: :$uidvalidity,
        message_id: :$message_id,
        date: :$date,
        from: :$from,
        subject: :$subject,
        has_attachments: :$has_attachments,
        x_gm_labels: :$x_gm_labels,
        x_gm_msgid: :$x_gm_msgid,
        x_gm_thrid: :$x_gm_thrid,
        flags: :$flags,
        encoded: :$encoded
      )
    end

    def prune_missing!(db, mailbox, uidvalidity, uids)
      return 0 if uids.nil? || uids.empty?
      db[:email].where(mailbox: mailbox, uidvalidity: uidvalidity, uid: uids).delete
    end

    # Configure SQLite pragmas for better concurrency and write performance.
    # When wal is true, enable WAL journaling and lower synchronous to NORMAL.
    # Always set a busy_timeout to avoid immediate lock errors.
    def configure_performance!(db, wal: true)
      # Use direct PRAGMA statements for compatibility across Sequel versions
      db.run("PRAGMA busy_timeout = 5000")
      if wal
        db.run("PRAGMA journal_mode = WAL")
        db.run("PRAGMA synchronous = NORMAL")
      end
      db
    end
  end
end

# Configure SQLite pragmas for better concurrency and write performance.
# When wal is true, enable WAL journaling and lower synchronous to NORMAL.
# Always set a busy_timeout to avoid immediate lock errors.
def configure_performance!(db, wal: true)
  # milliseconds
  db.pragma_set(:busy_timeout, 5000)
  if wal
    db.pragma_set(:journal_mode, :wal)
    db.pragma_set(:synchronous, :normal)
  end
  db
end
