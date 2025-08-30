#!/usr/bin/env ruby
# frozen_string_literal: true

# NittyMail MCP Server
# Provides Model Context Protocol server exposing email database tools
# Usage: ruby mcp_server.rb

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("Gemfile", __dir__)
require "bundler/setup"
require "dotenv/load"
require "json"
require "logger"

require_relative "lib/nittymail/db"
require_relative "lib/nittymail/query_tools"

class NittyMailMCPServer
  VERSION = "1.0.0"

  def initialize
    @logger = Logger.new($stderr, level: ENV.fetch("LOG_LEVEL", "INFO"))
    @database_path = ENV["DATABASE"]
    @address = ENV["ADDRESS"]

    validate_configuration!
    @logger.info("NittyMail MCP Server v#{VERSION} starting...")
    @logger.info("Database: #{@database_path}")
    @logger.info("Address context: #{@address || "none"}")
  end

  def run
    @logger.info("MCP Server listening on STDIN/STDOUT...")

    loop do
      request = nil
      begin
        line = $stdin.gets
        break if line.nil? # EOF

        line = line.strip
        next if line.empty?

        request = JSON.parse(line)
        response = handle_request(request)

        if response
          $stdout.puts(JSON.generate(response))
          $stdout.flush
        end
      rescue JSON::ParserError => e
        @logger.error("JSON parse error: #{e.message}")
        error_response = {
          jsonrpc: "2.0",
          id: 0,
          error: {
            code: -32700,
            message: "Parse error",
            data: e.message
          }
        }
        $stdout.puts(JSON.generate(error_response))
        $stdout.flush
      rescue => e
        @logger.error("Unexpected error: #{e.message}")
        @logger.error(e.backtrace.join("\n"))
        error_response = {
          jsonrpc: "2.0",
          id: request&.dig("id") || 0,
          error: {
            code: -32603,
            message: "Internal error",
            data: e.message
          }
        }
        $stdout.puts(JSON.generate(error_response))
        $stdout.flush
      end
    end
  end

  private

  def validate_configuration!
    unless @database_path
      raise "DATABASE environment variable is required"
    end

    unless File.exist?(@database_path)
      raise "Database file not found: #{@database_path}"
    end
  end

  def handle_request(request)
    method = request["method"]
    params = request["params"] || {}
    id = request["id"] || 0

    @logger.debug("Handling request: #{method}")

    case method
    when "initialize"
      handle_initialize(id, params)
    when "notifications/initialized"
      # Client acknowledges initialization complete - no response needed for notifications
      nil
    when "tools/list"
      handle_tools_list(id)
    when "tools/call"
      handle_tools_call(id, params)
    when "ping"
      handle_ping(id)
    else
      {
        jsonrpc: "2.0",
        id: id,
        error: {
          code: -32601,
          message: "Method not found",
          data: method
        }
      }
    end
  end

  def handle_initialize(id, params)
    {
      jsonrpc: "2.0",
      id: id,
      result: {
        protocolVersion: "2024-11-05",
        capabilities: {
          tools: {}
        },
        serverInfo: {
          name: "nittymail-mcp-server",
          version: VERSION
        }
      }
    }
  end

  def handle_tools_list(id)
    tools = NittyMail::QueryTools.tool_schemas.map do |tool|
      {
        name: tool.dig("function", "name"),
        description: tool.dig("function", "description"),
        inputSchema: tool.dig("function", "parameters")
      }
    end

    {
      jsonrpc: "2.0",
      id: id,
      result: {
        tools: tools
      }
    }
  end

  def handle_tools_call(id, params)
    tool_name = params["name"]
    arguments = params["arguments"] || {}

    @logger.debug("Calling tool: #{tool_name} with args: #{arguments.inspect}")

    begin
      result = execute_tool(tool_name, arguments)

      {
        jsonrpc: "2.0",
        id: id,
        result: {
          content: [
            {
              type: "text",
              text: JSON.generate(result)
            }
          ]
        }
      }
    rescue => e
      @logger.error("Tool execution error: #{e.message}")
      {
        jsonrpc: "2.0",
        id: id,
        error: {
          code: -32603,
          message: "Tool execution failed",
          data: e.message
        }
      }
    end
  end

  def handle_ping(id)
    {
      jsonrpc: "2.0",
      id: id,
      result: {
        status: "ok",
        timestamp: Time.now.iso8601
      }
    }
  end

  def execute_tool(tool_name, arguments)
    # Establish database connection for this request
    db = NittyMail::DB.connect(@database_path, wal: true, load_vec: true)
    NittyMail::DB.ensure_schema!(db)

    begin
      case tool_name
      when "db.list_earliest_emails"
        NittyMail::QueryTools.list_earliest_emails(
          db: db,
          address: @address,
          limit: arguments["limit"] || 100
        )
      when "db.get_email_full"
        NittyMail::QueryTools.get_email_full(
          db: db,
          address: @address,
          id: arguments["id"],
          mailbox: arguments["mailbox"],
          uid: arguments["uid"],
          uidvalidity: arguments["uidvalidity"],
          message_id: arguments["message_id"],
          from_contains: arguments["from_contains"],
          subject_contains: arguments["subject_contains"],
          date: arguments["date"],
          order: arguments["order"]
        )
      when "db.filter_emails"
        NittyMail::QueryTools.filter_emails(
          db: db,
          address: @address,
          from_contains: arguments["from_contains"],
          from_domain: arguments["from_domain"],
          subject_contains: arguments["subject_contains"],
          mailbox: arguments["mailbox"],
          date_from: arguments["date_from"],
          date_to: arguments["date_to"],
          order: arguments["order"],
          limit: arguments["limit"] || 100
        )
      when "db.search_emails"
        NittyMail::QueryTools.search_emails(
          db: db,
          query: arguments["query"],
          item_types: arguments["item_types"] || ["subject", "body"],
          limit: arguments["limit"] || 100,
          ollama_host: ENV["OLLAMA_HOST"]
        )
      when "db.count_emails"
        count = NittyMail::QueryTools.count_emails(
          db: db,
          address: @address,
          from_contains: arguments["from_contains"],
          from_domain: arguments["from_domain"],
          subject_contains: arguments["subject_contains"],
          mailbox: arguments["mailbox"],
          date_from: arguments["date_from"],
          date_to: arguments["date_to"]
        )
        {count: count}
      when "db.get_email_stats"
        NittyMail::QueryTools.get_email_stats(
          db: db,
          address: @address,
          top_limit: arguments["top_limit"] || 10
        )
      when "db.get_largest_emails"
        NittyMail::QueryTools.get_largest_emails(
          db: db,
          address: @address,
          limit: (arguments["limit"] || 5).to_i,
          attachments: arguments["attachments"] || "any",
          mailbox: arguments["mailbox"],
          from_domain: arguments["from_domain"]
        )
      when "db.get_top_senders"
        NittyMail::QueryTools.get_top_senders(
          db: db,
          address: @address,
          limit: arguments["limit"] || 20,
          mailbox: arguments["mailbox"]
        )
      when "db.get_top_domains"
        NittyMail::QueryTools.get_top_domains(
          db: db,
          address: @address,
          limit: arguments["limit"] || 20
        )
      when "db.get_mailbox_stats"
        NittyMail::QueryTools.get_mailbox_stats(
          db: db,
          address: @address
        )
      when "db.get_emails_by_date_range"
        NittyMail::QueryTools.get_emails_by_date_range(
          db: db,
          address: @address,
          period: arguments["period"] || "monthly",
          date_from: arguments["date_from"],
          date_to: arguments["date_to"],
          limit: arguments["limit"] || 50
        )
      when "db.get_emails_with_attachments"
        NittyMail::QueryTools.get_emails_with_attachments(
          db: db,
          address: @address,
          mailbox: arguments["mailbox"],
          date_from: arguments["date_from"],
          date_to: arguments["date_to"],
          limit: arguments["limit"] || 100
        )
      when "db.get_email_thread"
        NittyMail::QueryTools.get_email_thread(
          db: db,
          address: @address,
          thread_id: arguments["thread_id"],
          order: arguments["order"] || "date_asc"
        )
      else
        {error: "Unknown tool: #{tool_name}"}
      end
    ensure
      db&.disconnect
    end
  end
end

# Run the server if this file is executed directly
if __FILE__ == $0
  begin
    server = NittyMailMCPServer.new
    server.run
  rescue => e
    warn "Failed to start MCP server: #{e.message}"
    exit 1
  end
end
