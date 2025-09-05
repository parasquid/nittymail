# frozen_string_literal: true

# Keep existing Chroma helper for now (Task 2 removes usage),
# and introduce ActiveRecord-backed SQLite setup functions.

require "chroma-db"

module NittyMail
  module DB
    module_function

    # --------------------
    # Chroma (legacy path)
    # --------------------
    def chroma_collection(collection_name, host: nil, api_base: nil, api_version: nil)
      host ||= ENV["NITTYMAIL_CHROMA_HOST"] || "http://chroma:8000"
      api_base = ENV["NITTYMAIL_CHROMA_API_BASE"] if api_base.nil?
      api_version = ENV["NITTYMAIL_CHROMA_API_VERSION"] if api_version.nil?

      Chroma.connect_host = host
      Chroma.api_base = api_base unless api_base.to_s.empty?
      Chroma.api_version = api_version unless api_version.to_s.empty?

      Chroma::Resources::Collection.get_or_create(collection_name)
    end

    # -----------------------
    # ActiveRecord / SQLite3
    # -----------------------
    def default_database_path
      # Allow override via env; otherwise local file under cli/
      env_path = ENV["NITTYMAIL_SQLITE_DB"].to_s
      return env_path unless env_path.empty?
      File.expand_path("nittymail.sqlite3", __dir__ + "/..")
    end

    def establish_sqlite_connection(database_path: nil)
      require "active_record"
      db_path = (database_path || default_database_path).to_s
      FileUtils.mkdir_p(File.dirname(db_path)) unless Dir.exist?(File.dirname(db_path))
      ActiveRecord::Base.establish_connection(
        adapter: "sqlite3",
        database: db_path
      )
      # Performance pragmas suitable for bulk insert workloads
      conn = ActiveRecord::Base.connection
      conn.execute("PRAGMA journal_mode=WAL;")
      conn.execute("PRAGMA synchronous=NORMAL;")
      conn.execute("PRAGMA temp_store=MEMORY;")
      conn
    end

    def migrations_path
      File.expand_path("../db/migrate", __dir__)
    end

    def run_migrations!
      require "active_record"
      establish_sqlite_connection unless ActiveRecord::Base.connected?
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        # Ensure schema metadata tables exist on AR 7/8
        begin
          conn.schema_migration.create_table if conn.respond_to?(:schema_migration)
        rescue
        end
        begin
          conn.internal_metadata.create_table if conn.respond_to?(:internal_metadata)
        rescue
        end

        if conn.respond_to?(:migration_context)
          conn.migration_context.migrate
        else
          ActiveRecord::MigrationContext.new([migrations_path]).migrate
        end
      end
    end
  end
end
