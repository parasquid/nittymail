# Database Schema

This is the database schema implementation for the spec detailed in @.agent-os/specs/2025-09-05-sqlite-mailbox-download/spec.md

## Changes

- New table: `emails`
- New indexes: composite uniqueness on (`address`,`mailbox`,`uidvalidity`,`uid`); btree on `internaldate_epoch`; optional index on `subject`.
- Initial migration to create table and indexes; no foreign keys required.

## Specifications

### ActiveRecord Migration (proposed)

```ruby
class CreateEmails < ActiveRecord::Migration[7.2]
  def change
    create_table :emails do |t|
      t.string  :address,             null: false
      t.string  :mailbox,             null: false
      t.integer :uidvalidity,         null: false
      t.integer :uid,                 null: false
      t.text    :subject
      t.datetime :internaldate,       null: false
      t.integer :internaldate_epoch,  null: false
      t.integer :rfc822_size
      t.string  :from_email
      t.text    :to_emails
      t.text    :cc_emails
      t.text    :bcc_emails
      t.text    :labels_json
      t.binary  :raw,                 null: false
      t.text    :plain_text
      t.text    :markdown
      t.timestamps
    end

    add_index :emails, [:address, :mailbox, :uidvalidity, :uid], unique: true, name: "index_emails_on_identity"
    add_index :emails, :internaldate_epoch
    add_index :emails, :subject
  end
end
```

### SQLite PRAGMAs (set on connection)

```ruby
ActiveRecord::Base.connection.execute("PRAGMA journal_mode=WAL;")
ActiveRecord::Base.connection.execute("PRAGMA synchronous=NORMAL;")
ActiveRecord::Base.connection.execute("PRAGMA temp_store=MEMORY;")
```

### Data Handling Notes

- `raw` is stored verbatim (BLOB). Always write exactly the RFC822 bytes received.
- `internaldate` comes from IMAP `INTERNALDATE`; `internaldate_epoch` is cached as integer for indexing and fast range queries.
- Email lists (`to_emails`, `cc_emails`, `bcc_emails`) may be stored as comma-delimited strings or JSON array serialized as text (implementation choice consistent across the codebase).
- `labels_json` is a JSON-encoded array when labels are available; nullable otherwise.

## Rationale

- Composite unique key mirrors IMAP identity and enables resumable, idempotent syncing.
- WAL + batched transactions significantly improve write throughput over autocommit.
- Separate `plain_text` and `markdown` columns allow simple indexing and fast reads without external vector stores.
- Storing `internaldate_epoch` avoids costly conversions during range queries and simplifies sorting by time.
