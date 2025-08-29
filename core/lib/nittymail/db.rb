# frozen_string_literal: true

module NittyMail
  module DB
    module_function

    def ensure_schema!(db)
      # Enable foreign keys for referential integrity
      begin
        db.run("PRAGMA foreign_keys = ON")
      rescue
        # Best-effort; ignore if not supported in current context
      end

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

      # Require sqlite-vec virtual tables for vector search. No fallback.
      vec_dimension = (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i
      ensure_vec_tables!(db, dimension: vec_dimension)

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

    # Best-effort loading of sqlite-vec. If SQLITE_VEC_EXTENSION env var is set,
    # attempts to load that library; otherwise tries 'vec0' by name.
    def load_sqlite_vec!(db)
      return true if defined?(@sqlite_vec_loaded) && @sqlite_vec_loaded
      lib = ENV["SQLITE_VEC_EXTENSION"]
      db.synchronize do |conn|
        begin
          conn.enable_load_extension(true) if conn.respond_to?(:enable_load_extension)
        rescue
        end

        if lib && !lib.empty?
          begin
            conn.load_extension(lib)
          rescue
            # try SQL fallback
            begin
              db.run("SELECT load_extension('#{lib.gsub("'", "''")}')")
            rescue
              raise "Failed to load sqlite-vec extension from #{lib}. Set SQLITE_VEC_EXTENSION to the shared library path inside the container."
            end
          end
        else
          # try default module name
          begin
            conn.load_extension("vec0")
          rescue
            begin
              db.run("SELECT load_extension('vec0')")
            rescue
              raise "sqlite-vec extension not found. Provide SQLITE_VEC_EXTENSION pointing to the vec0 library."
            end
          end
        end
      ensure
        begin
          conn.enable_load_extension(false) if conn.respond_to?(:enable_load_extension)
        rescue
        end
      end
      @sqlite_vec_loaded = true
      true
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
