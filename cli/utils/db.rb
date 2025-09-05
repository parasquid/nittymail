# frozen_string_literal: true

module NittyMail
  module DB
    module_function

    # -----------------------
    # ActiveRecord / SQLite3
    # -----------------------
    def default_database_path(address: nil)
      # Allow override via env; otherwise local file under cli/
      env_path = ENV["NITTYMAIL_SQLITE_DB"].to_s
      return env_path unless env_path.empty?
      basename = address.to_s.empty? ? "nittymail.sqlite3" : "#{address}.sqlite3"
      File.expand_path(basename, File.expand_path("..", __dir__))
    end

    def establish_sqlite_connection(database_path: nil, address: nil)
      require "active_record"
      db_path = (database_path || default_database_path(address: address)).to_s
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
