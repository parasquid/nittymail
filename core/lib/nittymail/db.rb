# frozen_string_literal: true

require "sqlite3"
require "sequel"
require "sqlite_vec"

module NittyMail
  module DB
    module_function

    # Open a Sequel SQLite connection with common settings.
    # When load_vec is true, ensure sqlite-vec is loaded for every underlying connection.
    def connect(database_path, wal: true, load_vec: false)
      db = if load_vec
        Sequel.sqlite(
          database_path,
          after_connect: proc do |conn|
            begin
              conn.enable_load_extension(true) if conn.respond_to?(:enable_load_extension)
            rescue
            end
            begin
              SqliteVec.load(conn)
            rescue
            ensure
              begin
                conn.enable_load_extension(false) if conn.respond_to?(:enable_load_extension)
              rescue
              end
            end
          end
        )
      else
        Sequel.sqlite(database_path)
      end
      configure_performance!(db, wal: wal)
      db
    end

    def ensure_schema!(db)
      # Enable foreign keys for referential integrity
      begin
        db.run("PRAGMA foreign_keys = ON")
      rescue
        # Best-effort; ignore if not supported in current context
      end

      if db.table_exists?(:email)
        # Ensure new enrichment columns exist on older databases
        ensure_enrichment_columns!(db)
      else
        db.create_table :email do
          primary_key :id
          String :address, index: true
          String :mailbox, index: true
          Bignum :uid, index: true, default: 0
          Integer :uidvalidity, index: true, default: 0

          String :message_id, index: true
          DateTime :date, index: true
          DateTime :internaldate, index: true
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

      # Require sqlite-vec virtual tables for vector search. No fallback.
      vec_dimension = (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i
      ensure_vec_tables!(db, dimension: vec_dimension)

      db[:email]
    end

    # Ensure helpful indexes exist for common query patterns used by QueryTools.
    # These are created idempotently and on existing databases as needed.
    def ensure_query_indexes!(db)
      db.run("CREATE INDEX IF NOT EXISTS email_idx_address_date ON email(address, date)")
      db.run("CREATE INDEX IF NOT EXISTS email_idx_mailbox_date ON email(mailbox, date)")
      db.run("CREATE INDEX IF NOT EXISTS email_idx_x_gm_thrid_date ON email(x_gm_thrid, date)")
      db.run("CREATE INDEX IF NOT EXISTS email_idx_has_attachments_date ON email(has_attachments, date)")
      db
    end

    # Add enrichment columns reconstructed from the raw message (encoded)
    # - internaldate (DateTime): captured from IMAP INTERNALDATE during sync
    # - rfc822_size (Integer): bytesize of raw encoded message
    # - envelope_* fields as JSON strings for address lists and references
    def ensure_enrichment_columns!(db)
      cols = db.schema(:email).map { |c| c.first }
      db.alter_table(:email) { add_column :internaldate, DateTime } unless cols.include?(:internaldate)
      db.alter_table(:email) { add_column :rfc822_size, Integer } unless cols.include?(:rfc822_size)
      %i[envelope_to envelope_cc envelope_bcc envelope_reply_to envelope_in_reply_to envelope_references].each do |col|
        unless cols.include?(col)
          db.alter_table(:email) { add_column col, String }
        end
      end
      db
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
        internaldate: :$internaldate,
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
      db.run("PRAGMA foreign_keys = ON")
      if wal
        db.run("PRAGMA journal_mode = WAL")
        db.run("PRAGMA synchronous = NORMAL")
      end
      db
    end

    # Attempt to load sqlite-vec extension and create virtual tables for embeddings.
    # Raises if vec is unavailable.
    def ensure_vec_tables!(db, dimension: 1024)
      load_sqlite_vec!(db)
      begin
        db.run("CREATE VIRTUAL TABLE IF NOT EXISTS email_vec USING vec0(embedding float[#{dimension}])")
        unless db.table_exists?(:email_vec_meta)
          db.create_table :email_vec_meta do
            primary_key :id
            Integer :vec_rowid, unique: true, index: true # rowid of email_vec
            foreign_key :email_id, :email, on_delete: :cascade, index: true
            String :item_type, null: false, default: "body", index: true
            String :model, null: false, index: true
            Integer :dimension, null: false, default: dimension
            DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP

            unique %i[email_id item_type model]
          end
        end
      end
    end

    # Load sqlite-vec via the Ruby gem helper.
    def load_sqlite_vec!(db)
      return true if defined?(@sqlite_vec_loaded) && @sqlite_vec_loaded
      db.synchronize do |conn|
        conn.enable_load_extension(true) if conn.respond_to?(:enable_load_extension)
        SqliteVec.load(conn)
        conn.enable_load_extension(false) if conn.respond_to?(:enable_load_extension)
      end
      @sqlite_vec_loaded = true
      true
    end

    # Insert a new embedding into the vec table and create a metadata row
    # that links it to an existing email record.
    #
    # Params:
    # - db: Sequel::Database connection (opened to the target SQLite file)
    # - email_id: Integer ID from the `email` table
    # - vector: Array(Float) embedding with exact length == dimension
    # - item_type: String describing the source (e.g., 'body', 'subject')
    # - model: String model identifier (defaults to ENV['EMBEDDING_MODEL'] or 'mxbai-embed-large')
    # - dimension: Integer embedding dimension; defaults to ENV['SQLITE_VEC_DIMENSION'] or 1024
    #
    # Returns the rowid (Integer) in the vec virtual table for the inserted embedding.
    def insert_email_embedding!(db, email_id:, vector:, item_type: "body", model: ENV.fetch("EMBEDDING_MODEL", "mxbai-embed-large"), dimension: (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i)
      raise ArgumentError, "vector must be an Array of Floats" unless vector.is_a?(Array)
      raise ArgumentError, "vector length #{vector.length} does not match dimension #{dimension}" unless vector.length == dimension

      # Ensure schema and vec tables exist for the configured dimension
      ensure_schema!(db)
      ensure_vec_tables!(db, dimension: dimension)

      packed = vector.pack("f*")
      vec_rowid = nil
      db.transaction do
        db.synchronize do |conn|
          conn.execute("INSERT INTO email_vec(embedding) VALUES (?)", SQLite3::Blob.new(packed))
          vec_rowid = conn.last_insert_row_id
        end
        db[:email_vec_meta].insert(vec_rowid: vec_rowid, email_id: email_id, item_type: item_type.to_s, model: model, dimension: dimension)
      end
      vec_rowid
    end

    # Upsert an embedding for a given (email_id, item_type, model).
    # If metadata exists, update the underlying vector in-place; otherwise insert new.
    # Returns the vec_rowid.
    def upsert_email_embedding!(db, email_id:, vector:, item_type: "body", model: ENV.fetch("EMBEDDING_MODEL", "mxbai-embed-large"), dimension: (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i)
      raise ArgumentError, "vector must be an Array of Floats" unless vector.is_a?(Array)
      raise ArgumentError, "vector length #{vector.length} does not match dimension #{dimension}" unless vector.length == dimension

      ensure_schema!(db)
      ensure_vec_tables!(db, dimension: dimension)

      packed = vector.pack("f*")
      item_type_str = item_type.to_s
      meta = db[:email_vec_meta].where(email_id: email_id, item_type: item_type_str, model: model).first
      if meta
        if meta[:dimension].to_i != dimension
          raise ArgumentError, "existing embedding dimension #{meta[:dimension]} does not match requested dimension #{dimension}"
        end
        db.synchronize do |conn|
          conn.execute("UPDATE email_vec SET embedding = ? WHERE rowid = ?", SQLite3::Blob.new(packed), meta[:vec_rowid])
        end
        meta[:vec_rowid]
      else
        insert_email_embedding!(db, email_id: email_id, vector: vector, item_type: item_type_str, model: model, dimension: dimension)
      end
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
