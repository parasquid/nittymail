require "spec_helper"

RSpec.describe "ActiveRecord SQLite setup" do
  Given(:db_path) { File.expand_path("../../tmp/test.sqlite3", __dir__) }

  before do
    require_relative "../../utils/db"
    require "fileutils"
    FileUtils.mkdir_p(File.dirname(db_path))
    # Establish connection and run migrations against a test DB file
    NittyMail::DB.establish_sqlite_connection(database_path: db_path)
    NittyMail::DB.run_migrations!
  end

  after do
    # Cleanup test database file

    File.delete(db_path) if File.exist?(db_path)
    wal = db_path + "-wal"
    shm = db_path + "-shm"
    File.delete(wal) if File.exist?(wal)
    File.delete(shm) if File.exist?(shm)
  rescue
  end

  Then "emails table exists with key columns" do
    require "active_record"
    cols = ActiveRecord::Base.connection.columns(:emails).map(&:name)
    expect(cols).to include("address", "mailbox", "uidvalidity", "uid", "raw", "internaldate", "internaldate_epoch")
  end
end
