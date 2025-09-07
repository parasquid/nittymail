require "spec_helper"

RSpec.describe "DB MCP server" do
  Given(:db_path) { "/tmp/test-mcp-#{Process.pid}.sqlite3" }

  before do
    ENV["NITTYMAIL_SQLITE_DB"] = db_path
    require_relative "../../utils/db"
    NittyMail::DB.establish_sqlite_connection(database_path: db_path)
    NittyMail::DB.run_migrations!
    require_relative "../../models/email"
    # Seed a few rows
    3.times do |i|
      NittyMail::Email.upsert_all([
        {
          address: "mcp@example.com",
          mailbox: "INBOX",
          uidvalidity: 1,
          uid: i + 1,
          subject: "S#{i}",
          internaldate: Time.at(1_700_000_000 + i),
          internaldate_epoch: 1_700_000_000 + i,
          rfc822_size: 10 + i,
          from_email: "x@y.z",
          raw: "Subject: S#{i}\n\nB",
          created_at: Time.now,
          updated_at: Time.now
        }
      ], unique_by: "index_emails_on_identity")
    end
  end

  after do
    [db_path, db_path + "-wal", db_path + "-shm"].each { |p| File.delete(p) if File.exist?(p) }
  rescue
  end

  def rpc(id:, method:, params: {})
    {jsonrpc: "2.0", id:, method:, params:}.to_json + "\n"
  end

  Then "initialize, list tools, and call count/list" do
    require_relative "../../commands/db/mcp"
    r_in, w_in = IO.pipe
    r_out, w_out = IO.pipe
    server = NittyMail::Commands::DB::MCPServer.new(max_limit: 100, quiet: true)
    thr = Thread.new { server.run(r_in, w_out, $stderr) }

    # initialize
    w_in.write rpc(id: 1, method: "initialize")
    init = JSON.parse(r_out.gets)
    expect(init["result"]).to have_key("capabilities")

    # list
    w_in.write rpc(id: 2, method: "tools/list")
    listed = JSON.parse(r_out.gets)
    names = listed.dig("result", "tools").map { |t| t["name"] }
    expect(names).to include("db.count_emails", "db.list_earliest_emails")

    # call count
    w_in.write rpc(id: 3, method: "tools/call", params: {name: "db.count_emails", arguments: {}})
    resp = JSON.parse(r_out.gets)
    obj = JSON.parse(resp.dig("result", "content").first["text"])
    expect(obj["count"]).to eq(3)

    # call list
    w_in.write rpc(id: 4, method: "tools/call", params: {name: "db.list_earliest_emails", arguments: {limit: 2}})
    resp2 = JSON.parse(r_out.gets)
    arr = JSON.parse(resp2.dig("result", "content").first["text"])
    expect(arr.size).to eq(2)
    expect(arr.first).to have_key("internaldate")
    expect(arr.first).to have_key("internaldate_epoch")

    # shutdown
    w_in.write rpc(id: 5, method: "shutdown")
    shut = JSON.parse(r_out.gets)
    expect(shut).to have_key("result")

    w_in.close
    r_in.close
    w_out.close
    r_out.close
    thr.join
  end
end
