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
              # Skip invalid requests silently to avoid protocol issues
              next
            end
            id = req["id"]
            is_notification = id.nil?

            case req["method"]
            when "initialize"
              write(io_out, {
                jsonrpc: "2.0",
                id:,
                result: {
                  protocolVersion: "2024-11-05",
                  capabilities: {tools: {}},
                  serverInfo: {
                    name: "nittymail-db-mcp-server",
                    version: "1.0.0"
                  }
                }
              })
            when "tools/list"
              tools = available_tools_with_schemas
              write(io_out, {jsonrpc: "2.0", id:, result: {tools:}})
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
            when "notifications/initialized"
              # Handle MCP initialized notification - no response needed
              log(io_err, "mcp:initialized")
            else
              if is_notification
                # For unknown notifications, just log and ignore (no response)
                log(io_err, "mcp:unknown_notification method=#{req["method"]}")
              else
                # For unknown requests, log and skip to avoid protocol errors
                log(io_err, "mcp:unknown_method method=#{req["method"]} id=#{id}")
              end
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
          # Per JSON-RPC spec: id should be null if request id couldn't be determined
          response_id = id.nil? ? nil : id
          {jsonrpc: "2.0", id: response_id, error: {code:, message:}}
        end

        def log(io, msg)
          return if @quiet
          io.puts(msg)
          io.flush
        rescue
        end

        def available_tools_with_schemas
          [
            {
              name: "db.list_earliest_emails",
              description: "Lists the earliest emails in the database by date",
              inputSchema: {
                type: "object",
                properties: {
                  limit: {type: "integer", description: "Maximum number of results (default: 100)"}
                },
                additionalProperties: false
              }
            },
            {
              name: "db.get_email_full",
              description: "Retrieves the complete email record by ID, including raw content",
              inputSchema: {
                type: "object",
                properties: {
                  id: {type: "integer", description: "Email database ID"}
                },
                required: ["id"],
                additionalProperties: false
              }
            },
            {
              name: "db.filter_emails",
              description: "Filters emails by mailbox and sender criteria",
              inputSchema: {
                type: "object",
                properties: {
                  mailbox: {type: "string", description: "Mailbox name to filter by"},
                  from_contains: {type: "string", description: "Text to search in from field"},
                  from_domain: {type: "string", description: "Domain to filter sender by"},
                  limit: {type: "integer", description: "Maximum number of results (default: 100)"}
                },
                additionalProperties: false
              }
            },
            {
              name: "db.search_emails",
              description: "Vector search emails (currently stubbed)",
              inputSchema: {
                type: "object",
                properties: {
                  query: {type: "string", description: "Search query"},
                  limit: {type: "integer", description: "Maximum number of results"}
                },
                required: ["query"],
                additionalProperties: false
              }
            },
            {
              name: "db.count_emails",
              description: "Simple count of emails, optionally filtered by mailbox",
              inputSchema: {
                type: "object",
                properties: {
                  mailbox: {type: "string", description: "Mailbox to count emails in"}
                },
                additionalProperties: false
              }
            },
            {
              name: "db.get_email_stats",
              description: "Provides comprehensive database statistics",
              inputSchema: {
                type: "object",
                properties: {},
                additionalProperties: false
              }
            },
            {
              name: "db.get_top_senders",
              description: "Lists top email senders by message count",
              inputSchema: {
                type: "object",
                properties: {
                  limit: {type: "integer", description: "Maximum number of results (default: 20)"}
                },
                additionalProperties: false
              }
            },
            {
              name: "db.get_top_domains",
              description: "Lists top sender domains by message count",
              inputSchema: {
                type: "object",
                properties: {
                  limit: {type: "integer", description: "Maximum number of results (default: 10)"}
                },
                additionalProperties: false
              }
            },
            {
              name: "db.get_largest_emails",
              description: "Lists emails by size (largest first)",
              inputSchema: {
                type: "object",
                properties: {
                  from_domain: {type: "string", description: "Filter by sender domain"},
                  limit: {type: "integer", description: "Maximum number of results (default: 5)"}
                },
                additionalProperties: false
              }
            },
            {
              name: "db.get_mailbox_stats",
              description: "Shows email count by mailbox",
              inputSchema: {
                type: "object",
                properties: {},
                additionalProperties: false
              }
            },
            {
              name: "db.get_emails_by_date_range",
              description: "Retrieves emails within a specific date range",
              inputSchema: {
                type: "object",
                properties: {
                  start_date: {type: "string", description: "Start date in ISO format or parseable format"},
                  end_date: {type: "string", description: "End date in ISO format or parseable format"},
                  limit: {type: "integer", description: "Maximum number of results (default: 100)"}
                },
                required: ["start_date", "end_date"],
                additionalProperties: false
              }
            },
            {
              name: "db.get_emails_with_attachments",
              description: "Lists emails that have attachments",
              inputSchema: {
                type: "object",
                properties: {
                  limit: {type: "integer", description: "Maximum number of results (default: 50)"}
                },
                additionalProperties: false
              }
            },
            {
              name: "db.get_email_thread",
              description: "Retrieves all emails in a Gmail thread",
              inputSchema: {
                type: "object",
                properties: {
                  x_gm_thrid: {type: "integer", description: "Gmail thread ID"},
                  limit: {type: "integer", description: "Maximum number of results (default: 50)"}
                },
                required: ["x_gm_thrid"],
                additionalProperties: false
              }
            },
            {
              name: "db.get_email_activity_heatmap",
              description: "Shows email activity patterns by hour of day and day of week",
              inputSchema: {
                type: "object",
                properties: {
                  limit: {type: "integer", description: "Maximum number of data points (default: 168)"}
                },
                additionalProperties: false
              }
            },
            {
              name: "db.get_response_time_stats",
              description: "Analyzes response times in email conversations",
              inputSchema: {
                type: "object",
                properties: {
                  limit: {type: "integer", description: "Maximum number of threads to analyze (default: 50)"}
                },
                additionalProperties: false
              }
            },
            {
              name: "db.get_email_frequency_by_sender",
              description: "Shows email frequency over time for a specific sender",
              inputSchema: {
                type: "object",
                properties: {
                  sender_email: {type: "string", description: "Email address to analyze"},
                  limit: {type: "integer", description: "Maximum number of date points (default: 365)"}
                },
                required: ["sender_email"],
                additionalProperties: false
              }
            },
            {
              name: "db.get_seasonal_trends",
              description: "Shows email volume trends by month and year",
              inputSchema: {
                type: "object",
                properties: {
                  limit: {type: "integer", description: "Maximum number of data points (default: 24)"}
                },
                additionalProperties: false
              }
            },
            {
              name: "db.get_emails_by_size_range",
              description: "Finds emails within a specific size range",
              inputSchema: {
                type: "object",
                properties: {
                  min_size: {type: "integer", description: "Minimum size in bytes (must be >= 0)"},
                  max_size: {type: "integer", description: "Maximum size in bytes (must be > min_size)"},
                  limit: {type: "integer", description: "Maximum number of results (default: 50)"}
                },
                required: ["min_size", "max_size"],
                additionalProperties: false
              }
            },
            {
              name: "db.get_duplicate_emails",
              description: "Finds emails with duplicate message IDs or Gmail message IDs",
              inputSchema: {
                type: "object",
                properties: {
                  field: {type: "string", description: "Field to check for duplicates (default: message_id)", enum: ["message_id", "x_gm_msgid"]},
                  limit: {type: "integer", description: "Maximum number of results (default: 50)"}
                },
                additionalProperties: false
              }
            },
            {
              name: "db.search_email_headers",
              description: "Searches within email header fields",
              inputSchema: {
                type: "object",
                properties: {
                  query: {type: "string", description: "Search query"},
                  header_field: {type: "string", description: "Field to search in (default: subject)", enum: ["subject", "from", "to_emails", "cc_emails", "bcc_emails", "message_id"]},
                  limit: {type: "integer", description: "Maximum number of results (default: 50)"}
                },
                required: ["query"],
                additionalProperties: false
              }
            },
            {
              name: "db.get_emails_by_keywords",
              description: "Searches email content by keywords with AND/OR logic",
              inputSchema: {
                type: "object",
                properties: {
                  keywords: {type: "string", description: "Keywords to search for (comma-separated)"},
                  search_field: {type: "string", description: "Field to search in (default: plain_text)", enum: ["plain_text", "markdown", "subject", "raw"]},
                  match_all: {type: "boolean", description: "If true, all keywords must match (AND logic). If false, any keyword can match (OR logic). Default: false"},
                  limit: {type: "integer", description: "Maximum number of results (default: 50)"}
                },
                required: ["keywords"],
                additionalProperties: false
              }
            },
            {
              name: "db.execute_sql_query",
              description: "Executes a read-only SQL query with safety validation",
              inputSchema: {
                type: "object",
                properties: {
                  sql_query: {type: "string", description: "SQL query to execute (SELECT or WITH only)"}
                },
                required: ["sql_query"],
                additionalProperties: false
              }
            }
          ]
        end

        def call_tool(name, args)
          case name
          when "db.count_emails"
            count_emails(args)
          when "db.list_earliest_emails"
            list_earliest_emails(args)
          when "db.get_email_full"
            get_email_full(args)
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
          # Group 1: Basic analytics and filtering
          when "db.get_email_stats"
            get_email_stats(args)
          when "db.get_top_domains"
            get_top_domains(args)
          when "db.get_emails_by_date_range"
            get_emails_by_date_range(args)
          when "db.get_emails_with_attachments"
            get_emails_with_attachments(args)
          when "db.get_email_thread"
            get_email_thread(args)
          # Group 2: Advanced analytics and patterns
          when "db.get_email_activity_heatmap"
            get_email_activity_heatmap(args)
          when "db.get_response_time_stats"
            get_response_time_stats(args)
          when "db.get_email_frequency_by_sender"
            get_email_frequency_by_sender(args)
          when "db.get_seasonal_trends"
            get_seasonal_trends(args)
          # Group 3: Specialized search and filtering
          when "db.get_emails_by_size_range"
            get_emails_by_size_range(args)
          when "db.get_duplicate_emails"
            get_duplicate_emails(args)
          when "db.search_email_headers"
            search_email_headers(args)
          when "db.get_emails_by_keywords"
            get_emails_by_keywords(args)
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

        def get_email_full(args)
          email_id = args["id"]
          raise ToolError, "id is required" if email_id.to_s.empty?

          # Get full email record including raw content
          email = NittyMail::Email.find_by(id: email_id.to_i)
          raise ToolError, "email not found with id: #{email_id}" unless email

          # Return all available fields
          email_attrs = email.attributes
          symbolize_and_normalize(email_attrs)
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
          ds = NittyMail::Email.where.not(from_email: [nil, ""]).group(:from_email).order(Arel.sql("COUNT(*) DESC")).limit(limit).count
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
          rows = ds.select("emails.*", "LENGTH(raw) AS size_bytes").order(Arel.sql("size_bytes DESC")).limit(limit).map(&:attributes)
          rows.map { |h| symbolize_and_normalize(h) }
        end

        def get_mailbox_stats(_args)
          ds = NittyMail::Email.group(:mailbox).order(Arel.sql("COUNT(*) DESC")).count
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

        # Group 1: Basic analytics and filtering
        def get_email_stats(args)
          total_emails = NittyMail::Email.count
          unique_senders = NittyMail::Email.where.not(from_email: [nil, ""]).distinct.count(:from_email)
          total_size = NittyMail::Email.sum("LENGTH(raw)")
          avg_size = (total_emails > 0) ? total_size / total_emails : 0
          mailbox_count = NittyMail::Email.distinct.count(:mailbox)
          date_range = NittyMail::Email.select("MIN(internaldate_epoch) as earliest_epoch, MAX(internaldate_epoch) as latest_epoch").first
          earliest = date_range.earliest_epoch ? Time.at(date_range.earliest_epoch).iso8601 : nil
          latest = date_range.latest_epoch ? Time.at(date_range.latest_epoch).iso8601 : nil

          {
            total_emails:,
            unique_senders:,
            total_size_bytes: total_size,
            average_size_bytes: avg_size,
            mailbox_count:,
            date_range: {earliest:, latest:}
          }
        end

        def get_top_domains(args)
          limit = clamp_limit(args["limit"], default: 10)
          ds = NittyMail::Email.where.not(from_email: [nil, ""])
            .select("SUBSTR(from_email, INSTR(from_email, '@') + 1) AS domain")
            .group("domain")
            .order(Arel.sql("COUNT(*) DESC"))
            .limit(limit)
            .count
          ds.map { |domain, count| {domain: domain.to_s, count: count.to_i} }
        end

        def get_emails_by_date_range(args)
          start_date = args["start_date"]
          end_date = args["end_date"]
          limit = clamp_limit(args["limit"], default: 100)

          raise ToolError, "start_date is required" if start_date.to_s.empty?
          raise ToolError, "end_date is required" if end_date.to_s.empty?

          # Parse dates and convert to epoch
          begin
            start_epoch = Time.parse(start_date).to_i
            end_epoch = Time.parse(end_date).to_i
          rescue ArgumentError => e
            raise ToolError, "invalid date format: #{e.message}"
          end

          ds = NittyMail::Email.where(internaldate_epoch: start_epoch..end_epoch)
          rows = ds.order(:internaldate_epoch).limit(limit).select(*base_projection).map(&:attributes)
          rows.map { |h| symbolize_and_normalize(h) }
        end

        def get_emails_with_attachments(args)
          limit = clamp_limit(args["limit"], default: 50)
          ds = NittyMail::Email.where(has_attachments: true)
          rows = ds.order(internaldate_epoch: :desc).limit(limit).select(*base_projection).map(&:attributes)
          rows.map { |h| symbolize_and_normalize(h) }
        end

        def get_email_thread(args)
          x_gm_thrid = args["x_gm_thrid"]
          raise ToolError, "x_gm_thrid is required" if x_gm_thrid.to_s.empty?

          limit = clamp_limit(args["limit"], default: 50)
          ds = NittyMail::Email.where(x_gm_thrid: x_gm_thrid.to_i)
          rows = ds.order(:internaldate_epoch).limit(limit).select(*base_projection).map(&:attributes)
          rows.map { |h| symbolize_and_normalize(h) }
        end

        # Group 2: Advanced analytics and patterns
        def get_email_activity_heatmap(args)
          # Return email counts by hour of day (0-23) and day of week (0-6, Sunday=0)
          limit = clamp_limit(args["limit"], default: 168) # 24*7 max

          # Use strftime to extract hour and weekday from internaldate_epoch
          results = NittyMail::Email.select(
            "strftime('%H', datetime(internaldate_epoch, 'unixepoch')) as hour_of_day",
            "strftime('%w', datetime(internaldate_epoch, 'unixepoch')) as day_of_week",
            "COUNT(*) as count"
          ).group("hour_of_day, day_of_week")
            .order("day_of_week, hour_of_day")
            .limit(limit)

          results.map do |row|
            {
              hour_of_day: row.hour_of_day.to_i,
              day_of_week: row.day_of_week.to_i,
              count: row.count.to_i
            }
          end
        end

        def get_response_time_stats(args)
          # Basic response time analysis using x_gm_thrid for threads
          limit = clamp_limit(args["limit"], default: 50)

          # Find threads with multiple emails (conversations)
          thread_data = NittyMail::Email.where.not(x_gm_thrid: [nil, 0])
            .group(:x_gm_thrid)
            .having("COUNT(*) > 1")
            .select(
              "x_gm_thrid",
              "COUNT(*) as message_count",
              "MIN(internaldate_epoch) as first_message_epoch",
              "MAX(internaldate_epoch) as last_message_epoch",
              "(MAX(internaldate_epoch) - MIN(internaldate_epoch)) as thread_duration_seconds"
            ).order(Arel.sql("thread_duration_seconds DESC"))
            .limit(limit)

          thread_data.map do |row|
            {
              x_gm_thrid: row.x_gm_thrid.to_i,
              message_count: row.message_count.to_i,
              first_message: Time.at(row.first_message_epoch).iso8601,
              last_message: Time.at(row.last_message_epoch).iso8601,
              duration_seconds: row.thread_duration_seconds.to_i,
              duration_hours: (row.thread_duration_seconds.to_f / 3600).round(2)
            }
          end
        end

        def get_email_frequency_by_sender(args)
          sender_email = args["sender_email"]
          raise ToolError, "sender_email is required" if sender_email.to_s.empty?

          # Sanitize the sender email for LIKE query
          safe_sender = like(sender_email)

          # Get email frequency by date for this sender
          results = NittyMail::Email.where("LOWER(from_email) LIKE ? ESCAPE '\\'", safe_sender.downcase)
            .select(
              "date(datetime(internaldate_epoch, 'unixepoch')) as email_date",
              "COUNT(*) as count"
            ).group("email_date")
            .order("email_date")
            .limit(clamp_limit(args["limit"], default: 365))

          results.map do |row|
            {
              date: row.email_date,
              count: row.count.to_i
            }
          end
        end

        def get_seasonal_trends(args)
          # Show email volume trends by month and year
          limit = clamp_limit(args["limit"], default: 24) # 2 years of months

          results = NittyMail::Email.select(
            "strftime('%Y', datetime(internaldate_epoch, 'unixepoch')) as year",
            "strftime('%m', datetime(internaldate_epoch, 'unixepoch')) as month",
            "COUNT(*) as count"
          ).group("year, month")
            .order("year, month")
            .limit(limit)

          results.map do |row|
            {
              year: row.year.to_i,
              month: row.month.to_i,
              month_name: Date::MONTHNAMES[row.month.to_i],
              count: row.count.to_i
            }
          end
        end

        # Group 3: Specialized search and filtering
        def get_emails_by_size_range(args)
          min_size = args["min_size"].to_i
          max_size = args["max_size"].to_i
          limit = clamp_limit(args["limit"], default: 50)

          raise ToolError, "min_size must be >= 0" if min_size < 0
          raise ToolError, "max_size must be > min_size" if max_size <= min_size

          # Use LENGTH(raw) to check size
          ds = NittyMail::Email.where("LENGTH(raw) BETWEEN ? AND ?", min_size, max_size)
          rows = ds.select(*base_projection, "LENGTH(raw) AS size_bytes")
            .order(Arel.sql("size_bytes DESC"))
            .limit(limit)
            .map(&:attributes)
          rows.map { |h| symbolize_and_normalize(h) }
        end

        def get_duplicate_emails(args)
          # Find emails with identical message_id or x_gm_msgid
          limit = clamp_limit(args["limit"], default: 50)
          field = args["field"] || "message_id"

          unless %w[message_id x_gm_msgid].include?(field)
            raise ToolError, "field must be 'message_id' or 'x_gm_msgid'"
          end

          # Find duplicates based on the field
          duplicates_query = NittyMail::Email.where.not(field => [nil, ""])
            .group(field)
            .having("COUNT(*) > 1")
            .select(field)
            .limit(limit / 2) # Get fewer groups to stay within limit

          duplicate_ids = duplicates_query.pluck(field.to_sym)
          return [] if duplicate_ids.empty?

          # Get all emails with these duplicate IDs
          ds = NittyMail::Email.where(field => duplicate_ids)
          rows = ds.order(:internaldate_epoch).limit(limit).select(*base_projection).map(&:attributes)
          rows.map { |h| symbolize_and_normalize(h) }
        end

        def search_email_headers(args)
          query = args["query"]
          header_field = args["header_field"] || "subject"
          limit = clamp_limit(args["limit"], default: 50)

          raise ToolError, "query is required" if query.to_s.empty?

          # Supported header fields that we have in the database
          valid_fields = %w[subject from to_emails cc_emails bcc_emails message_id]
          unless valid_fields.include?(header_field)
            raise ToolError, "header_field must be one of: #{valid_fields.join(", ")}"
          end

          # Sanitize query for LIKE
          safe_query = like(query)
          header_field.to_sym

          ds = NittyMail::Email.where("LOWER(#{header_field}) LIKE ? ESCAPE '\\'", safe_query.downcase)
          rows = ds.order(internaldate_epoch: :desc).limit(limit).select(*base_projection).map(&:attributes)
          rows.map { |h| symbolize_and_normalize(h) }
        end

        def get_emails_by_keywords(args)
          keywords = args["keywords"]
          search_field = args["search_field"] || "plain_text"
          match_all = args["match_all"] == true # default false (OR search)
          limit = clamp_limit(args["limit"], default: 50)

          raise ToolError, "keywords is required" if keywords.to_s.empty?

          # Parse keywords (comma-separated or array)
          keyword_list = case keywords
          when Array
            keywords.map(&:to_s).map(&:strip).reject(&:empty?)
          else
            keywords.to_s.split(",").map(&:strip).reject(&:empty?)
          end

          raise ToolError, "at least one keyword required" if keyword_list.empty?

          # Supported search fields
          valid_fields = %w[plain_text markdown subject raw]
          unless valid_fields.include?(search_field)
            raise ToolError, "search_field must be one of: #{valid_fields.join(", ")}"
          end

          # Build query conditions
          ds = NittyMail::Email.where.not(search_field => [nil, ""])

          if match_all
            # AND search - all keywords must be present
            keyword_list.each do |keyword|
              safe_keyword = like(keyword)
              ds = ds.where("LOWER(#{search_field}) LIKE ? ESCAPE '\\'", safe_keyword.downcase)
            end
          else
            # OR search - any keyword can match
            conditions = keyword_list.map do |keyword|
              safe_keyword = like(keyword)
              ["LOWER(#{search_field}) LIKE ? ESCAPE '\\'", safe_keyword.downcase]
            end

            # Combine with OR
            where_clause = conditions.map(&:first).join(" OR ")
            values = conditions.map(&:last)
            ds = ds.where(where_clause, *values)
          end

          rows = ds.order(internaldate_epoch: :desc).limit(limit).select(*base_projection).map(&:attributes)
          rows.map { |h| symbolize_and_normalize(h) }
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
