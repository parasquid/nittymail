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
          when "db.filter_emails"
            filter_emails(args)
          when "db.get_top_senders"
            get_top_senders(args)
          when "db.get_largest_emails"
            get_largest_emails(args)
          when "db.get_mailbox_stats"
            get_mailbox_stats(args)
          when "db.execute_sql_query"
            execute_sql_query(args)
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

        def filter_emails(args)
          ds = NittyMail::Email
          if (mb = args["mailbox"]) && !mb.to_s.empty?
            ds = ds.where(mailbox: mb)
          end
          if (fc = args["from_contains"]) && !fc.to_s.empty?
            ds = ds.where("LOWER(from) LIKE ? ESCAPE '\\' OR LOWER(from_email) LIKE ? ESCAPE '\\'", like(fc), like(fc))
          end
          if (fd = args["from_domain"]) && !fd.to_s.empty?
            dom = fd.to_s.start_with?("@") ? fd.to_s[1..] : fd.to_s
            ds = ds.where("LOWER(from_email) LIKE ? ESCAPE '\\'", like("@#{dom}"))
          end
          if (sc = args["subject_contains"]) && !sc.to_s.empty?
            ds = ds.where("LOWER(subject) LIKE ? ESCAPE '\\'", like(sc))
          end
          if (df = args["date_from"]) && !df.to_s.empty?
            begin
              t = Time.parse(df.to_s)
              ds = ds.where("internaldate_epoch >= ?", t.to_i)
            rescue
            end
          end
          if (dt = args["date_to"]) && !dt.to_s.empty?
            begin
              t = Time.parse(dt.to_s)
              ds = ds.where("internaldate_epoch <= ?", t.to_i)
            rescue
            end
          end
          order = args["order"].to_s
          if order == "date_asc"
            ds = ds.order(:internaldate_epoch)
          else
            ds = begin
              ds.order(Sequel.desc(:internaldate_epoch))
            rescue
              ds.order(internaldate_epoch: :desc)
            end
            ds = ds.order(internaldate_epoch: :desc) # ActiveRecord fallback
          end
          limit = clamp_limit(args["limit"], default: 100)
          rows = ds.limit(limit).select(*base_projection).map(&:attributes)
          rows.map { |h| symbolize_and_normalize(h) }
        end

        def get_top_senders(args)
          limit = clamp_limit(args["limit"], default: 20)
          ds = NittyMail::Email.where.not(from_email: [nil, ""]).group(:from_email).order("COUNT(*) DESC").limit(limit).count
          # ActiveRecord group(...).count returns {"from_email"=>count} or { [colvals]=>count }
          ds.map { |k, v| {from: (k.is_a?(Array) ? k.first : k), count: v.to_i} }
        end

        def get_largest_emails(args)
          limit = clamp_limit(args["limit"], default: 5)
          ds = NittyMail::Email
          case args["attachments"].to_s
          when "with"
            ds = ds.where(has_attachments: true)
          when "without"
            ds = ds.where(has_attachments: false)
          end
          if (mb = args["mailbox"]) && !mb.to_s.empty?
            ds = ds.where(mailbox: mb)
          end
          if (fd = args["from_domain"]) && !fd.to_s.empty?
            dom = fd.to_s.start_with?("@") ? fd.to_s[1..] : fd.to_s
            ds = ds.where("LOWER(from_email) LIKE ? ESCAPE '\\'", like("@#{dom}"))
          end
          rows = ds.select("emails.*", "LENGTH(raw) AS size_bytes").order("size_bytes DESC").limit(limit).map(&:attributes)
          rows.map { |h| symbolize_and_normalize(h) }
        end

        def get_mailbox_stats(_args)
          ds = NittyMail::Email.group(:mailbox).order("COUNT(*) DESC").count
          ds.map { |k, v| {mailbox: (k.is_a?(Array) ? k.first : k), count: v.to_i} }
        end

        def execute_sql_query(args)
          sql = (args["sql_query"] || "").to_s.strip
          raise ToolError, "sql_query is required" if sql.empty?
          safe_sql = ensure_readonly_sql(sql)
          # enforce limit
          unless /\blimit\b/i.match?(safe_sql)
            safe_sql = safe_sql.sub(/;\s*\z/, "")
            safe_sql += " LIMIT #{@max_limit}"
          end
          rows = []
          conn = ActiveRecord::Base.connection
          res = conn.select_all(safe_sql)
          res.each do |r|
            rows << r
          end
          {query: safe_sql, row_count: rows.size, rows: rows}
        end

        def ensure_readonly_sql(sql)
          s = sql.dup
          s = s.strip
          s = s.sub(/;\s*\z/, "")
          # Single statement basic check
          raise ToolError, "multiple statements not allowed" if s.split(";").size > 1
          start = s[/\A\s*(\w+)/, 1].to_s.downcase
          unless %w[select with].include?(start)
            raise ToolError, "only SELECT/WITH allowed"
          end
          forbidden = %w[insert update delete drop create alter truncate pragma begin commit rollback vacuum attach detach]
          if forbidden.any? { |kw| s =~ /\b#{Regexp.escape(kw)}\b/i }
            raise ToolError, "forbidden keyword detected"
          end
          s
        end

        def like(term)
          t = term.to_s.downcase
          t = t.gsub("\\", "\\\\").gsub("%", "\\%").gsub("_", "\\_")
          "%#{t}%"
        end

        def symbolize_and_normalize(h)
          # ActiveRecord returns string keys; normalize as needed
          h.transform_keys { |k| k.to_s.to_sym }
        end
      end
    end
  end
end
