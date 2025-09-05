require "spec_helper"

RSpec.describe "Default DB path naming" do
  Given(:address) { "john.doe+test@example.com" }

  Then "uses [IMAP_ADDRESS].sqlite3 in cli folder by default" do
    require_relative "../../utils/db"
    # ensure env override does not affect this test
    orig = ENV.delete("NITTYMAIL_SQLITE_DB")
    begin
      path = NittyMail::DB.default_database_path(address: address)
      cli_root = File.expand_path("../..", __dir__)
      expect(path).to eq(File.join(cli_root, "#{address}.sqlite3"))
    ensure
      ENV["NITTYMAIL_SQLITE_DB"] = orig if orig
    end
  end
end
