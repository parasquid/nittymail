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
  end
end
