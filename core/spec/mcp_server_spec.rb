# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "timeout"
require_relative "../lib/nittymail/query_tools"

describe "NittyMail MCP Server" do
  before(:all) do
    cmd = "ruby ./mcp_server.rb"
    env = {
      "LOG_LEVEL" => "ERROR",
      "DATABASE" => "data/query_given.sqlite3",
      "ADDRESS" => "spec@example.com"
    }
    @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(env, cmd)
    # Drain stderr to avoid pipe buffer blocking
    @stderr_thread = Thread.new do
      @stderr.each_line { |_l| }
    rescue IOError
    end
  end

  after(:all) do
    @stdin.close
    @stdout.close
    @stderr.close
    begin
      @wait_thr.join(1)
    rescue
    end
    @stderr_thread&.kill
  end

  it "responds to initialize" do
    init_request = {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: {name: "rspec-test-client", version: "1.0.0"}
      }
    }
    @stdin.puts(JSON.generate(init_request))
    @stdin.flush

    line = Timeout.timeout(5) { @stdout.gets }
    expect(line).not_to be_nil
    response = JSON.parse(line.strip)
    expect(response.dig("result", "serverInfo", "name")).to eq("nittymail-mcp-server")
  end

  it "lists the available tools" do
    list_request = {
      jsonrpc: "2.0",
      id: 2,
      method: "tools/list"
    }
    @stdin.puts(JSON.generate(list_request))
    @stdin.flush

    line = Timeout.timeout(5) { @stdout.gets }
    expect(line).not_to be_nil
    response = JSON.parse(line.strip)
    tools_count = response.dig("result", "tools")&.length || 0
    expected = NittyMail::QueryTools.tool_schemas.length
    expect(tools_count).to eq(expected)
  end

  it "calls the db.get_email_stats tool" do
    call_request = {
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: {
        name: "db.get_email_stats",
        arguments: {top_limit: 5}
      }
    }
    @stdin.puts(JSON.generate(call_request))
    @stdin.flush

    line = Timeout.timeout(5) { @stdout.gets }
    expect(line).not_to be_nil
    response = JSON.parse(line.strip)
    expect(response["result"]).to be_a(Hash)
    content = JSON.parse(response.dig("result", "content", 0, "text"))
    expect(content).to have_key("total_emails")
  end

  it "responds to ping" do
    ping_request = {
      jsonrpc: "2.0",
      id: 4,
      method: "ping"
    }
    @stdin.puts(JSON.generate(ping_request))
    @stdin.flush

    line = Timeout.timeout(5) { @stdout.gets }
    expect(line).not_to be_nil
    response = JSON.parse(line.strip)
    expect(response.dig("result", "status")).to eq("ok")
  end
end
