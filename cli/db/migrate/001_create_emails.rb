# frozen_string_literal: true

class CreateEmails < ActiveRecord::Migration[8.0]
  def change
    create_table :emails do |t|
      t.string :address, null: false
      t.string :mailbox, null: false
      t.integer :uidvalidity, null: false
      t.integer :uid, null: false

      # Identifiers
      t.string :message_id
      t.integer :x_gm_thrid, limit: 8
      t.integer :x_gm_msgid, limit: 8

      t.text :subject
      t.datetime :internaldate, null: false
      t.integer :internaldate_epoch, null: false
      t.integer :rfc822_size

      # Sender/Participants
      t.string :from_email
      t.text :from
      t.text :to_emails
      t.text :cc_emails
      t.text :bcc_emails
      t.text :envelope_reply_to
      t.string :envelope_in_reply_to
      t.text :envelope_references

      # Parsed Date header (may differ from INTERNALDATE)
      t.datetime :date

      # Attachment presence flag
      t.boolean :has_attachments, null: false, default: false

      t.text :labels_json
      t.binary :raw, null: false
      t.text :plain_text
      t.text :markdown
      t.timestamps
    end

    add_index :emails, [:address, :mailbox, :uidvalidity, :uid], unique: true, name: "index_emails_on_identity"
    add_index :emails, :internaldate_epoch
    add_index :emails, :subject
    add_index :emails, :message_id
    add_index :emails, :x_gm_thrid
    add_index :emails, :from_email
    add_index :emails, :date
    add_index :emails, :x_gm_msgid
  end
end
