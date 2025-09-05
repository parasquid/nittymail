# frozen_string_literal: true

require "thor"
require "json"
require_relative "../../utils/db"
require_relative "../../models/email"

module NittyMail
  module Commands
    class DB < Thor
      desc "mcp", "Run MCP stdio server for DB tools (no IMAP)"
      method_option :database, type: :string, required: false, desc: "SQLite database path (env NITTYMAIL_SQLITE_DB or cli/data/<ADDRESS>.sqlite3)"
      method_option :address, type: :string, required: false, desc: "Email address context (env NITTYMAIL_IMAP_ADDRESS)"
      method_option :max_limit, type: :numeric, required: false, desc: "Max rows for list endpoints (env NITTYMAIL_MCP_MAX_LIMIT, default 1000)"
      method_option :quiet, type: :boolean, default: false, desc: "Reduce stderr logging (env NITTYMAIL_QUIET)"
      def mcp
        address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
        db_path = options[:database]
        max_limit = (options[:max_limit] || ENV["NITTYMAIL_MCP_MAX_LIMIT"]).to_i
        max_limit = 1000 if max_limit <= 0
        quiet = options.key?(:quiet) ? !!options[:quiet] : (ENV["NITTYMAIL_QUIET"] == "1")

        # DB connection
        NittyMail::DB.establish_sqlite_connection(database_path: db_path, address: address)
        NittyMail::DB.run_migrations!

        server = MCPServer.new(max_limit: max_limit, quiet: quiet)
        server.run($stdin, $stdout, $stderr)
      end

      class MCPServer
        def initialize(max_limit:, quiet: false)
          @max_limit = max_limit
          @quiet = quiet
        end

        def run(io_in, io_out, io_err)
          log(io_err, "mcp:start")
          while (line = io_in.gets)
            line = line.to_s.strip
            next if line.empty?
            req = begin
              JSON.parse(line)
            rescue
              nil
            end
            unless req && req["jsonrpc"] == "2.0" && req["method"]
              write(io_out, error(nil, -32600, "Invalid Request"))
              next
            end
            id = req["id"]
            case req["method"]
            when "initialize"
              write(io_out, {jsonrpc: "2.0", id:, result: {capabilities: {tools: {}}}})
            when "tools/list"
              tools = available_tools
              write(io_out, {jsonrpc: "2.0", id:, result: {tools: tools.map { |name| {name:} }}})
            when "tools/call"
              name = req.dig("params", "name")
              args = req.dig("params", "arguments") || {}
              t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              result_obj = call_tool(name, args)
              t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              log(io_err, "mcp:call name=#{name} dur_ms=#{((t1 - t0) * 1000).round}")
              write(io_out, {jsonrpc: "2.0", id:, result: {content: [{type: "text", text: JSON.generate(result_obj)}]}})
            when "shutdown"
              write(io_out, {jsonrpc: "2.0", id:, result: {}})
              break
            else
              write(io_out, error(id, -32601, "Method not found"))
            end
          end
        ensure
          log(io_err, "mcp:stop")
        end

        private

        def write(io, obj)
          io.write(JSON.generate(obj) + "\n")
          io.flush
        rescue
        end

        def error(id, code, message)
          {jsonrpc: "2.0", id:, error: {code:, message:}}
        end

        def log(io, msg)
          return if @quiet
          io.puts(msg)
          io.flush
        rescue
        end

        def available_tools
          %w[
            db.list_earliest_emails
            db.get_email_full
            db.filter_emails
            db.search_emails
            db.count_emails
            db.get_email_stats
            db.get_top_senders
            db.get_top_domains
            db.get_largest_emails
            db.get_mailbox_stats
            db.get_emails_by_date_range
            db.get_emails_with_attachments
            db.get_email_thread
            db.get_email_activity_heatmap
            db.get_response_time_stats
            db.get_email_frequency_by_sender
            db.get_seasonal_trends
            db.get_emails_by_size_range
            db.get_duplicate_emails
            db.search_email_headers
            db.get_emails_by_keywords
            db.execute_sql_query
          ]
        end

        def call_tool(name, args)
          case name
          when "db.count_emails"
            count_emails(args)
          when "db.list_earliest_emails"
            list_earliest_emails(args)
          when "db.search_emails"
            [] # stubbed for now
          else
            raise ToolError, "Unknown tool: #{name}"
          end
        rescue ToolError => e
          {error: e.message}
        end

        class ToolError < StandardError; end

        def clamp_limit(arg_limit, default: 100)
          limit = arg_limit.to_i
          limit = default if limit <= 0
          limit = @max_limit if limit > @max_limit
          limit
        end

        def base_projection
          %i[id address mailbox uid uidvalidity message_id x_gm_msgid date internaldate internaldate_epoch from subject rfc822_size]
        end

        def list_earliest_emails(args)
          limit = clamp_limit(args["limit"], default: 100)
          ds = NittyMail::Email
          # Prefer date ASC then internaldate_epoch ASC
          rows = ds.order(:date, :internaldate_epoch).limit(limit).select(*base_projection).map(&:attributes)
          rows.map { |h| symbolize_and_normalize(h) }
        end

        def count_emails(args)
          ds = NittyMail::Email
          ds = ds.where(mailbox: args["mailbox"]) if args["mailbox"]
          {count: ds.count}
        end

        def symbolize_and_normalize(h)
          # ActiveRecord returns string keys; normalize as needed
          h.transform_keys { |k| k.to_s.to_sym }
        end
      end
    end
  end
end
