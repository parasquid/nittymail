require "spec_helper"

RSpec.describe "DB MCP tools" do
  Given(:db_path) { "/tmp/test-mcp-tools-#{Process.pid}.sqlite3" }

  before do
    ENV["NITTYMAIL_SQLITE_DB"] = db_path
    require_relative "../../utils/db"
    NittyMail::DB.establish_sqlite_connection(database_path: db_path)
    NittyMail::DB.run_migrations!
    require_relative "../../models/email"
    # Seed rows across mailboxes and senders
    data = [
      {uid: 1, subj: "Hello A", from: "alice@test.dev", mb: "INBOX", size: 50, has_att: false, epoch: 1_700_000_000},
      {uid: 2, subj: "Report", from: "bob@test.dev", mb: "INBOX", size: 150, has_att: true, epoch: 1_700_000_100},
      {uid: 3, subj: "Hello B", from: "alice@test.dev", mb: "Work", size: 2500, has_att: true, epoch: 1_700_000_200}
    ]
    data.each do |d|
      raw = "Subject: #{d[:subj]}\n\nBody"
      NittyMail::Email.upsert_all([
        {
          address: "mcp@example.com",
          mailbox: d[:mb],
          uidvalidity: 1,
          uid: d[:uid],
          subject: d[:subj],
          internaldate: Time.at(d[:epoch]),
          internaldate_epoch: d[:epoch],
          rfc822_size: d[:size],
          from_email: d[:from],
          has_attachments: d[:has_att],
          raw: raw,
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

  Given(:server) do
    require_relative "../../commands/db/mcp"
    NittyMail::Commands::DB::MCPServer.new(max_limit: 100, quiet: true)
  end

  Then "filter/top_senders/largest/mailbox_stats/sql all work" do
    r_in, w_in = IO.pipe
    r_out, w_out = IO.pipe
    thr = Thread.new { server.run(r_in, w_out, $stderr) }

    w_in.write rpc(id: 1, method: "initialize")
    JSON.parse(r_out.gets)

    # filter by subject_contains
    w_in.write rpc(id: 2, method: "tools/call", params: {name: "db.filter_emails", arguments: {subject_contains: "hello", order: "date_asc"}})
    resp = JSON.parse(r_out.gets)
    arr = JSON.parse(resp.dig("result", "content").first["text"])
    expect(arr.size).to eq(2)
    expect(arr.first["subject"]).to match(/Hello/)

    # top senders
    w_in.write rpc(id: 3, method: "tools/call", params: {name: "db.get_top_senders", arguments: {limit: 5}})
    resp2 = JSON.parse(r_out.gets)
    tops = JSON.parse(resp2.dig("result", "content").first["text"])
    expect(tops.first["from"]).to eq("alice@test.dev")
    expect(tops.first["count"]).to eq(2)

    # largest emails
    w_in.write rpc(id: 4, method: "tools/call", params: {name: "db.get_largest_emails", arguments: {limit: 2}})
    resp3 = JSON.parse(r_out.gets)
    largest = JSON.parse(resp3.dig("result", "content").first["text"])
    expect(largest.first).to have_key("size_bytes")
    expect(largest.first["size_bytes"]).to be >= largest.last["size_bytes"]

    # mailbox stats
    w_in.write rpc(id: 5, method: "tools/call", params: {name: "db.get_mailbox_stats", arguments: {}})
    resp4 = JSON.parse(r_out.gets)
    mstats = JSON.parse(resp4.dig("result", "content").first["text"])
    expect(mstats.map { |x| x["mailbox"] }).to include("INBOX", "Work")

    # read-only SQL
    w_in.write rpc(id: 6, method: "tools/call", params: {name: "db.execute_sql_query", arguments: {sql_query: "SELECT mailbox, COUNT(*) as c FROM emails GROUP BY mailbox ORDER BY c DESC"}})
    resp5 = JSON.parse(r_out.gets)
    sqlres = JSON.parse(resp5.dig("result", "content").first["text"])
    expect(sqlres["row_count"]).to be >= 1
    expect(sqlres["rows"].first).to have_key("mailbox")

    # shutdown
    w_in.write rpc(id: 7, method: "shutdown")
    JSON.parse(r_out.gets)
    [w_in, r_in, w_out, r_out].each(&:close)
    thr.join
  end
end
