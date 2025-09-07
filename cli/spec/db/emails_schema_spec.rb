require "spec_helper"

RSpec.describe "Emails schema" do
  Given(:db_path) { "/tmp/test-schema-#{Process.pid}.sqlite3" }

  before do
    require_relative "../../utils/db"
    NittyMail::DB.establish_sqlite_connection(database_path: db_path)
    NittyMail::DB.run_migrations!
  end

  after do
    File.delete(db_path) if File.exist?(db_path)
    ["-wal", "-shm"].each do |suffix|
      f = db_path + suffix
      File.delete(f) if File.exist?(f)
    end
  rescue
  end

  Then "emails has all required columns" do
    require "active_record"
    cols = ActiveRecord::Base.connection.columns(:emails).map(&:name)
    expect(cols).to include(
      "address", "mailbox", "uidvalidity", "uid",
      "message_id", "x_gm_thrid", "x_gm_msgid",
      "subject", "internaldate", "internaldate_epoch",
      "rfc822_size", "from", "from_email",
      "to_emails", "cc_emails", "bcc_emails",
      "envelope_reply_to", "envelope_in_reply_to", "envelope_references",
      "date", "has_attachments",
      "labels_json", "raw", "plain_text", "markdown",
      "created_at", "updated_at"
    )
  end

  Then "emails has expected indexes" do
    require "active_record"
    conn = ActiveRecord::Base.connection
    indexes = conn.indexes(:emails)
    # Helper to find an index by column(s)
    def has_index_on?(indexes, cols, unique: false, name: nil)
      indexes.any? do |idx|
        (name.nil? || idx.name == name) &&
          idx.columns == Array(cols) &&
          (!!idx.unique) == !!unique
      end
    end

    expect(has_index_on?(indexes, %w[address mailbox uidvalidity uid], unique: true, name: "index_emails_on_identity")).to be(true)
    %w[internaldate_epoch subject message_id x_gm_thrid x_gm_msgid from_email date].each do |col|
      expect(has_index_on?(indexes, [col])).to be(true), "missing index on #{col}"
    end
  end
end
