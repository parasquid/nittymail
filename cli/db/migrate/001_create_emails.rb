# frozen_string_literal: true

class CreateEmails < ActiveRecord::Migration[8.0]
  def change
    create_table :emails do |t|
      t.string :address, null: false
      t.string :mailbox, null: false
      t.integer :uidvalidity, null: false
      t.integer :uid, null: false
      t.text :subject
      t.datetime :internaldate, null: false
      t.integer :internaldate_epoch, null: false
      t.integer :rfc822_size
      t.string :from_email
      t.text :to_emails
      t.text :cc_emails
      t.text :bcc_emails
      t.text :labels_json
      t.binary :raw, null: false
      t.text :plain_text
      t.text :markdown
      t.timestamps
    end

    add_index :emails, [:address, :mailbox, :uidvalidity, :uid], unique: true, name: "index_emails_on_identity"
    add_index :emails, :internaldate_epoch
    add_index :emails, :subject
  end
end
