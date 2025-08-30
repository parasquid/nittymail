# frozen_string_literal: true

require "json"

require_relative "db"
require_relative "embeddings"

module NittyMail
  module QueryTools
    module_function

    # Tool schemas for Ollama chat tools
    def tool_schemas
      [
        {
          "type" => "function",
          "function" => {
            "name" => "db.list_earliest_emails",
            "description" => "Fetch earliest emails ordered by date ascending.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "limit" => {"type" => "integer", "description" => "Max results; default 100 when omitted"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_email_full",
            "description" => "Fetch a single email and return full fields including raw encoded message. Prefer selecting by id, or by (mailbox, uid, uidvalidity), or message_id.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "id" => {"type" => "string"},
                "mailbox" => {"type" => "string"},
                "uid" => {"type" => "integer"},
                "uidvalidity" => {"type" => "integer"},
                "message_id" => {"type" => "string"},
                "from_contains" => {"type" => "string"},
                "subject_contains" => {"type" => "string"},
                "date" => {"type" => "string", "description" => "ISO date YYYY or YYYY-MM-DD"},
                "order" => {"type" => "string", "enum" => ["date_asc", "date_desc"], "description" => "If multiple match, pick earliest or latest"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.filter_emails",
            "description" => "List emails filtered by simple criteria: from/subject contains, mailbox, and date range.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "from_contains" => {"type" => "string", "description" => "Match substring in the From header (case-insensitive)"},
                "from_domain" => {"type" => "string", "description" => "Filter by sender domain, e.g., example.com"},
                "subject_contains" => {"type" => "string", "description" => "Match substring in the Subject (case-insensitive)"},
                "mailbox" => {"type" => "string", "description" => "Mailbox name to filter, e.g., INBOX or [Gmail]/Sent Mail"},
                "date_from" => {"type" => "string", "description" => "ISO date (YYYY-MM-DD) inclusive lower bound"},
                "date_to" => {"type" => "string", "description" => "ISO date (YYYY-MM-DD) inclusive upper bound"},
                "order" => {"type" => "string", "enum" => ["date_asc", "date_desc"], "description" => "Sort by date ascending or descending"},
                "limit" => {"type" => "integer", "description" => "Max results; default 100 when omitted"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.search_emails",
            "description" => "Semantic search over emails using vector similarity. Join results to the email table and return the most relevant.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "query" => {"type" => "string", "description" => "Natural language search query"},
                "item_types" => {"type" => "array", "items" => {"type" => "string", "enum" => ["subject", "body"]}, "description" => "Which fields to search embeddings for"},
                "limit" => {"type" => "integer", "description" => "Max results; default 100 when omitted"}
              },
              "required" => ["query"]
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.count_emails",
            "description" => "Count emails matching filters: from/subject contains, mailbox, date range.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "from_contains" => {"type" => "string"},
                "from_domain" => {"type" => "string"},
                "subject_contains" => {"type" => "string"},
                "mailbox" => {"type" => "string"},
                "date_from" => {"type" => "string"},
                "date_to" => {"type" => "string"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_email_stats",
            "description" => "Get overview statistics: total emails, date range, top senders/domains, mailbox distribution.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "top_limit" => {"type" => "integer", "description" => "Limit for top senders/domains (default 10)"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_top_senders",
            "description" => "Get most frequent email senders with their email counts.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "limit" => {"type" => "integer", "description" => "Max results (default 20)"},
                "mailbox" => {"type" => "string", "description" => "Filter by specific mailbox"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_top_domains",
            "description" => "Get most frequent sender domains with their email counts.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "limit" => {"type" => "integer", "description" => "Max results (default 20)"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_mailbox_stats",
            "description" => "Get email counts per mailbox/folder.",
            "parameters" => {
              "type" => "object",
              "properties" => {},
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_largest_emails",
            "description" => "Get the largest emails by stored raw size (length(encoded)), optionally filtering by attachments, mailbox, or sender domain.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "limit" => {"type" => "integer", "description" => "Max results (default 5)"},
                "attachments" => {"type" => "string", "enum" => ["any", "with", "without"], "description" => "Filter: any, only with attachments, or only without"},
                "mailbox" => {"type" => "string", "description" => "Optional mailbox filter (e.g., INBOX or [Gmail]/All Mail)"},
                "from_domain" => {"type" => "string", "description" => "Optional sender domain filter (e.g., example.com)"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_emails_by_date_range",
            "description" => "Get email volume statistics over time periods (daily, monthly, yearly).",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "period" => {"type" => "string", "enum" => ["daily", "monthly", "yearly"], "description" => "Aggregation period"},
                "date_from" => {"type" => "string", "description" => "Start date (YYYY-MM-DD)"},
                "date_to" => {"type" => "string", "description" => "End date (YYYY-MM-DD)"},
                "limit" => {"type" => "integer", "description" => "Max periods to return (default 50)"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_emails_with_attachments",
            "description" => "Filter emails that have attachments.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "mailbox" => {"type" => "string"},
                "date_from" => {"type" => "string"},
                "date_to" => {"type" => "string"},
                "limit" => {"type" => "integer", "description" => "Max results (default 100)"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_email_thread",
            "description" => "Get emails in the same Gmail thread by thread ID.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "thread_id" => {"type" => "string", "description" => "Gmail thread ID (x_gm_thrid)"},
                "order" => {"type" => "string", "enum" => ["date_asc", "date_desc"], "description" => "Sort order (default date_asc)"}
              },
              "required" => ["thread_id"]
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_email_activity_heatmap",
            "description" => "Get email volume by hour of day and day of week for activity heatmap visualization.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "date_from" => {"type" => "string", "description" => "ISO date (YYYY-MM-DD) inclusive lower bound"},
                "date_to" => {"type" => "string", "description" => "ISO date (YYYY-MM-DD) inclusive upper bound"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_response_time_stats",
            "description" => "Analyze response times between consecutive emails in Gmail threads.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "limit" => {"type" => "integer", "description" => "Max results (default 50)"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_email_frequency_by_sender",
            "description" => "Get email frequency patterns per sender over time periods.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "sender" => {"type" => "string", "description" => "Filter by sender (contains match)"},
                "period" => {"type" => "string", "enum" => ["daily", "monthly", "yearly"], "description" => "Aggregation period (default monthly)"},
                "limit" => {"type" => "integer", "description" => "Max results (default 50)"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_seasonal_trends",
            "description" => "Get email volume trends by month/season over multiple years.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "years_back" => {"type" => "integer", "description" => "Years to look back (default 3)"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_emails_by_size_range",
            "description" => "Filter emails by size categories: small (<10KB), medium (10KB-100KB), large (>100KB), huge (>1MB).",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "size_category" => {"type" => "string", "enum" => ["small", "medium", "large", "huge"], "description" => "Size category (default large)"},
                "limit" => {"type" => "integer", "description" => "Max results (default 100)"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_duplicate_emails",
            "description" => "Find potential duplicate emails by subject or message_id similarity.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "similarity_field" => {"type" => "string", "enum" => ["subject", "message_id"], "description" => "Field to check for duplicates (default subject)"},
                "limit" => {"type" => "integer", "description" => "Max results (default 100)"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.search_email_headers",
            "description" => "Search through email headers using pattern matching in raw RFC822 content.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "header_pattern" => {"type" => "string", "description" => "Pattern to search for in email headers"},
                "limit" => {"type" => "integer", "description" => "Max results (default 100)"}
              },
              "required" => []
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.get_emails_by_keywords",
            "description" => "Find emails containing specific keywords with frequency scoring.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "keywords" => {"type" => "array", "items" => {"type" => "string"}, "description" => "Keywords to search for"},
                "match_mode" => {"type" => "string", "enum" => ["any", "all"], "description" => "Match any or all keywords (default any)"},
                "limit" => {"type" => "integer", "description" => "Max results (default 100)"}
              },
              "required" => ["keywords"]
            }
          }
        },
        {
          "type" => "function",
          "function" => {
            "name" => "db.execute_sql_query",
            "description" => "Execute arbitrary read-only SQL SELECT queries against the email database. Only SELECT and WITH (CTE) statements are allowed. Destructive operations are blocked.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "sql_query" => {"type" => "string", "description" => "SQL SELECT query to execute. Must start with SELECT or WITH. Auto-limited to prevent runaway queries."},
                "limit" => {"type" => "integer", "description" => "Max rows to return if LIMIT not specified in query (default 1000)"}
              },
              "required" => ["sql_query"]
            }
          }
        }
      ]
    end

    # Get the largest emails by raw stored size (length(encoded)).
    # attachments: "any" (nil), "with" (true), "without" (false)
    def get_largest_emails(db:, address: nil, limit: 5, attachments: "any", mailbox: nil, from_domain: nil)
      lim = ((limit.to_i <= 0) ? 5 : limit.to_i)
      ds = db[:email]
      ds = ds.where(address: address) if address && !address.to_s.strip.empty?
      if mailbox && !mailbox.to_s.strip.empty?
        ds = ds.where(Sequel.ilike(:mailbox, mailbox.strip))
      end
      if from_domain && !from_domain.to_s.strip.empty?
        domain = from_domain.strip.sub(/^@/, "")
        ds = ds.where(Sequel.ilike(:from, "%@#{domain}%"))
      end
      case attachments.to_s
      when "with"
        ds = ds.where(has_attachments: true)
      when "without"
        ds = ds.where(has_attachments: false)
      end
      ds = ds.select(:id, :address, :mailbox, :uid, :uidvalidity, :message_id, :date, :from, :subject, Sequel.function(:length, :encoded).as(:size_bytes))
        .order(Sequel.desc(:size_bytes))
        .limit(lim)
      rows = ds.all
      safe_encode_result(rows.map { |r| symbolize_keys(r) })
    end

    # Execute earliest emails
    def list_earliest_emails(db:, address:, limit: 100)
      limit = ((limit.to_i <= 0) ? 100 : limit.to_i)
      ds = db[:email]
      ds = ds.where(address: address) if address && !address.to_s.strip.empty?
      rows = ds.order(Sequel.asc(:date)).limit(limit)
        .select(:id, :address, :mailbox, :uid, :uidvalidity, :message_id, :date, :from, :subject)
        .all
      result = rows.map { |r| symbolize_keys(r) }
      safe_encode_result(result)
    end

    # Filter by simple contains on from/subject (case-insensitive)
    def filter_emails(db:, address: nil, from_contains: nil, subject_contains: nil, from_domain: nil, mailbox: nil, date_from: nil, date_to: nil, order: nil, limit: 100)
      limit = ((limit.to_i <= 0) ? 100 : limit.to_i)
      ds = db[:email]
      ds = ds.where(address: address) if address && !address.to_s.strip.empty?
      if from_contains && !from_contains.to_s.strip.empty?
        ds = ds.where(Sequel.ilike(:from, "%#{from_contains.strip}%"))
      end
      if from_domain && !from_domain.to_s.strip.empty?
        domain = from_domain.strip
        domain = domain.sub(/^@/, "")
        ds = ds.where(Sequel.ilike(:from, "%@#{domain}%"))
      end
      if subject_contains && !subject_contains.to_s.strip.empty?
        ds = ds.where(Sequel.ilike(:subject, "%#{subject_contains.strip}%"))
      end
      if mailbox && !mailbox.to_s.strip.empty?
        ds = ds.where(Sequel.ilike(:mailbox, mailbox.strip))
      end
      if date_from && !date_from.to_s.strip.empty?
        begin
          from_d = Date.parse(date_from.to_s)
          ds = ds.where { Sequel[:date] >= from_d }
        rescue
        end
      end
      if date_to && !date_to.to_s.strip.empty?
        begin
          to_d = Date.parse(date_to.to_s)
          ds = ds.where { Sequel[:date] <= to_d }
        rescue
        end
      end
      case order.to_s.downcase
      when "date_asc", "asc", "ascending"
        ds = ds.order(Sequel.asc(:date))
      when "date_desc", "desc", "descending"
        ds = ds.order(Sequel.desc(:date))
      end
      ds = ds.limit(limit)
      rows = ds.select(:id, :address, :mailbox, :uid, :uidvalidity, :message_id, :date, :from, :subject).all
      result = rows.map { |r| symbolize_keys(r) }
      safe_encode_result(result)
    end

    # Semantic search via sqlite-vec nearest neighbors
    def search_emails(db:, query:, item_types: ["subject", "body"], limit: 100, ollama_host: nil)
      limit = ((limit.to_i <= 0) ? 100 : limit.to_i)

      begin
        # Get query embedding using configured model/dimension
        model = ENV["EMBEDDING_MODEL"] || "mxbai-embed-large"
        dimension = (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i
        vector = NittyMail::Embeddings.fetch_embedding(ollama_host: ollama_host, model: model, text: query.to_s)
        raise "embedding dimension mismatch" unless vector.length == dimension
        packed = vector.pack("f*")

        # Build SQL: search vec table, join meta->email, optionally filter item_types
        item_types = Array(item_types).map { |s| s.to_s.downcase }.uniq & %w[subject body]
        item_types = %w[subject body] if item_types.empty?

        sql = <<~SQL
          WITH nn AS (
            SELECT rowid AS vec_rowid, distance
            FROM email_vec
            WHERE embedding MATCH ?
            LIMIT ?
          )
          SELECT e.id, e.address, e.mailbox, e.uid, e.uidvalidity, e.message_id, e.date, e."from" as from, e.subject,
                 MIN(nn.distance) AS score
          FROM nn
          JOIN email_vec_meta m ON m.vec_rowid = nn.vec_rowid
          JOIN email e ON e.id = m.email_id
          WHERE m.item_type IN #{sql_in_list(item_types)}
          GROUP BY e.id
          ORDER BY score ASC
          LIMIT ?
        SQL

        binds = [SQLite3::Blob.new(packed), limit * 5, limit] # overfetch then group

        rows = db[sql, *binds].all

        # Apply encoding safety to each row individually to catch problematic records
        safe_rows = []
        rows.each_with_index do |row, i|
          safe_row = symbolize_keys(row)
          safe_row = safe_encode_result(safe_row)
          safe_rows << safe_row
        rescue => e
          # Skip problematic rows and log the issue
          puts "Warning: Skipping row #{i} due to encoding issue: #{e.message}" if $DEBUG
          next
        end

        safe_rows
      rescue => e
        # If vector search fails entirely, return empty results
        puts "Vector search failed: #{e.message}" if $DEBUG
        []
      end
    end

    # Count emails with same filters as filter_emails (no limit/order)
    def count_emails(db:, address: nil, from_contains: nil, subject_contains: nil, from_domain: nil, mailbox: nil, date_from: nil, date_to: nil)
      ds = db[:email]
      ds = ds.where(address: address) if address && !address.to_s.strip.empty?
      if from_contains && !from_contains.to_s.strip.empty?
        ds = ds.where(Sequel.ilike(:from, "%#{from_contains.strip}%"))
      end
      if from_domain && !from_domain.to_s.strip.empty?
        domain = from_domain.strip.sub(/^@/, "")
        ds = ds.where(Sequel.ilike(:from, "%@#{domain}%"))
      end
      if subject_contains && !subject_contains.to_s.strip.empty?
        ds = ds.where(Sequel.ilike(:subject, "%#{subject_contains.strip}%"))
      end
      if mailbox && !mailbox.to_s.strip.empty?
        ds = ds.where(Sequel.ilike(:mailbox, mailbox.strip))
      end
      if date_from && !date_from.to_s.strip.empty?
        begin
          from_d = Date.parse(date_from.to_s)
          ds = ds.where { Sequel[:date] >= from_d }
        rescue
        end
      end
      if date_to && !date_to.to_s.strip.empty?
        begin
          to_d = Date.parse(date_to.to_s)
          ds = ds.where { Sequel[:date] <= to_d }
        rescue
        end
      end
      ds.count
    end

    # Fetch a single email with raw encoded content by id or identifiers.
    def get_email_full(db:, address: nil, id: nil, mailbox: nil, uid: nil, uidvalidity: nil, message_id: nil, from_contains: nil, subject_contains: nil, date: nil, order: nil)
      ds = db[:email]
      ds = ds.where(address: address) if address && !address.to_s.strip.empty?
      if id && id.to_i > 0
        ds = ds.where(id: id.to_i)
      else
        ds = ds.where(mailbox: mailbox) if mailbox && !mailbox.to_s.strip.empty?
        ds = ds.where(uid: uid.to_i) if uid && uid.to_i > 0
        ds = ds.where(uidvalidity: uidvalidity.to_i) if uidvalidity && uidvalidity.to_i > 0
        ds = ds.where(message_id: message_id.to_s) if message_id && !message_id.to_s.strip.empty?
        ds = ds.where(Sequel.ilike(:from, "%#{from_contains.strip}%")) if from_contains && !from_contains.to_s.strip.empty?
        ds = ds.where(Sequel.ilike(:subject, "%#{subject_contains.strip}%")) if subject_contains && !subject_contains.to_s.strip.empty?
        if date && !date.to_s.strip.empty?
          s = date.to_s
          if /^\d{4}$/.match?(s)
            from_d = begin
              Date.parse("#{s}-01-01")
            rescue
              nil
            end
            to_d = begin
              Date.parse("#{s}-12-31")
            rescue
              nil
            end
            ds = ds.where { (Sequel[:date] >= from_d) & (Sequel[:date] <= to_d) } if from_d && to_d
          else
            d = begin
              Date.parse(s)
            rescue
              nil
            end
            if d
              start_of_day = d.to_time
              end_of_day = (d + 1).to_time
              ds = ds.where { (Sequel[:date] >= start_of_day) & (Sequel[:date] < end_of_day) }
            end
          end
        end
        case order
        when "date_asc"
          ds = ds.order(Sequel.asc(:date))
        when "date_desc"
          ds = ds.order(Sequel.desc(:date))
        end
      end
      row = ds.select(:id, :address, :mailbox, :uid, :uidvalidity, :message_id, :date, :from, :subject, :encoded).first
      return nil unless row
      result = symbolize_keys(row)
      safe_encode_result(result)
    end

    # Get overview statistics: total emails, date range, top senders/domains, mailbox distribution
    def get_email_stats(db:, address: nil, top_limit: 10)
      top_limit = ((top_limit.to_i <= 0) ? 10 : top_limit.to_i)

      ds = db[:email]
      ds = ds.where(address: address) if address && !address.to_s.strip.empty?

      # Basic stats
      total_emails = ds.count
      return {total_emails: 0} if total_emails == 0

      date_range = ds.select { [min(:date).as(:earliest), max(:date).as(:latest)] }.limit(1).first

      # Top senders
      top_senders = ds.group(:from).select(:from, Sequel.function(:count, Sequel.lit("*")).as(:count))
        .order(Sequel.desc(:count)).limit(top_limit).all

      # Top domains (extract from 'from' field)
      domain_sql = <<~SQL
        SELECT 
          CASE 
            WHEN instr("from", '@') > 0 
            THEN substr("from", instr("from", '@') + 1, length("from") - instr("from", '@') - 1)
            ELSE "from"
          END as domain,
          COUNT(*) as count
        FROM email
        #{address ? "WHERE address = ?" : ""}
        GROUP BY domain
        ORDER BY count DESC
        LIMIT ?
      SQL

      binds = address ? [address, top_limit] : [top_limit]
      top_domains = db[domain_sql, *binds].all

      # Mailbox distribution
      mailbox_stats = ds.group(:mailbox).select(:mailbox, Sequel.function(:count, Sequel.lit("*")).as(:count))
        .order(Sequel.desc(:count)).all

      result = {
        total_emails: total_emails,
        earliest_date: date_range[:earliest],
        latest_date: date_range[:latest],
        top_senders: top_senders.map { |r| symbolize_keys(r) },
        top_domains: top_domains.map { |r| symbolize_keys(r) },
        mailbox_distribution: mailbox_stats.map { |r| symbolize_keys(r) }
      }

      safe_encode_result(result)
    end

    # Get most frequent email senders with their email counts
    def get_top_senders(db:, address: nil, limit: 20, mailbox: nil)
      limit = ((limit.to_i <= 0) ? 20 : limit.to_i)
      ds = db[:email]
      ds = ds.where(address: address) if address && !address.to_s.strip.empty?
      ds = ds.where(Sequel.ilike(:mailbox, mailbox.strip)) if mailbox && !mailbox.to_s.strip.empty?

      rows = ds.group(:from).select(:from, Sequel.function(:count, Sequel.lit("*")).as(:count))
        .order(Sequel.desc(:count)).limit(limit).all
      result = rows.map { |r| symbolize_keys(r) }
      safe_encode_result(result)
    end

    # Get most frequent sender domains with their email counts
    def get_top_domains(db:, address: nil, limit: 20)
      limit = ((limit.to_i <= 0) ? 20 : limit.to_i)

      # Extract domain from 'from' field using SQL
      domain_sql = <<~SQL
        SELECT 
          CASE 
            WHEN instr("from", '@') > 0 
            THEN substr("from", instr("from", '@') + 1, length("from") - instr("from", '@') - 1)
            ELSE "from"
          END as domain,
          COUNT(*) as count
        FROM email
        #{address ? "WHERE address = ?" : ""}
        GROUP BY domain
        ORDER BY count DESC
        LIMIT ?
      SQL

      binds = address ? [address, limit] : [limit]
      rows = db[domain_sql, *binds].all
      result = rows.map { |r| symbolize_keys(r) }
      safe_encode_result(result)
    end

    # Get email counts per mailbox/folder
    def get_mailbox_stats(db:, address: nil)
      ds = db[:email]
      ds = ds.where(address: address) if address && !address.to_s.strip.empty?

      rows = ds.group(:mailbox).select(:mailbox, Sequel.function(:count, Sequel.lit("*")).as(:count))
        .order(Sequel.desc(:count)).all
      result = rows.map { |r| symbolize_keys(r) }
      safe_encode_result(result)
    end

    # Get email volume statistics over time periods (daily, monthly, yearly)
    def get_emails_by_date_range(db:, address: nil, period: "monthly", date_from: nil, date_to: nil, limit: 50)
      limit = ((limit.to_i <= 0) ? 50 : limit.to_i)
      period = period.to_s.downcase
      period = "monthly" unless %w[daily monthly yearly].include?(period)

      ds = db[:email]
      ds = ds.where(address: address) if address && !address.to_s.strip.empty?

      if date_from && !date_from.to_s.strip.empty?
        begin
          from_d = Date.parse(date_from.to_s)
          ds = ds.where { Sequel[:date] >= from_d }
        rescue
        end
      end
      if date_to && !date_to.to_s.strip.empty?
        begin
          to_d = Date.parse(date_to.to_s)
          ds = ds.where { Sequel[:date] <= to_d }
        rescue
        end
      end

      # SQLite date formatting based on period
      date_format = case period
      when "daily" then "%Y-%m-%d"
      when "monthly" then "%Y-%m"
      when "yearly" then "%Y"
      end

      rows = ds.select(
        Sequel.function(:strftime, date_format, :date).as(:period),
        Sequel.function(:count, Sequel.lit("*")).as(:count)
      ).group(:period).order(:period).limit(limit).all

      result = rows.map { |r| symbolize_keys(r) }
      safe_encode_result(result)
    end

    # Filter emails that have attachments
    def get_emails_with_attachments(db:, address: nil, mailbox: nil, date_from: nil, date_to: nil, limit: 100)
      limit = ((limit.to_i <= 0) ? 100 : limit.to_i)
      ds = db[:email]
      ds = ds.where(address: address) if address && !address.to_s.strip.empty?
      ds = ds.where(has_attachments: true)

      if mailbox && !mailbox.to_s.strip.empty?
        ds = ds.where(Sequel.ilike(:mailbox, mailbox.strip))
      end
      if date_from && !date_from.to_s.strip.empty?
        begin
          from_d = Date.parse(date_from.to_s)
          ds = ds.where { Sequel[:date] >= from_d }
        rescue
        end
      end
      if date_to && !date_to.to_s.strip.empty?
        begin
          to_d = Date.parse(date_to.to_s)
          ds = ds.where { Sequel[:date] <= to_d }
        rescue
        end
      end

      rows = ds.order(Sequel.desc(:date)).limit(limit)
        .select(:id, :address, :mailbox, :uid, :uidvalidity, :message_id, :date, :from, :subject)
        .all
      result = rows.map { |r| symbolize_keys(r) }
      safe_encode_result(result)
    end

    # Get emails in the same Gmail thread by thread ID
    def get_email_thread(db:, thread_id:, address: nil, order: "date_asc")
      return [] if thread_id.nil? || thread_id.to_s.strip.empty?

      ds = db[:email]
      ds = ds.where(address: address) if address && !address.to_s.strip.empty?
      ds = ds.where(x_gm_thrid: thread_id.to_s.strip)

      ds = case order.to_s
      when "date_desc"
        ds.order(Sequel.desc(:date))
      else
        ds.order(Sequel.asc(:date))
      end

      rows = ds.select(:id, :address, :mailbox, :uid, :uidvalidity, :message_id, :date, :from, :subject).all
      result = rows.map { |r| symbolize_keys(r) }
      safe_encode_result(result)
    end

    # Time-based Analytics Tools

    def get_email_activity_heatmap(db:, address: nil, date_from: nil, date_to: nil)
      # Get email volume by hour of day and day of week
      query = db[:email]
      query = query.where(address: address) if address
      query = query.where { date >= date_from } if date_from
      query = query.where { date <= date_to } if date_to

      # SQLite datetime functions to extract hour and day of week
      heatmap_data = query.select(
        Sequel.function(:strftime, '%H', :date).as(:hour_of_day),
        Sequel.function(:strftime, '%w', :date).as(:day_of_week),
        Sequel.function(:count, Sequel.lit('*')).as(:count)
      ).group(:hour_of_day, :day_of_week).all

      # Convert day_of_week numbers to names (0=Sunday, 1=Monday, etc.)
      days = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday]
      
      result = heatmap_data.map do |row|
        {
          hour: row[:hour_of_day].to_i,
          day_of_week: days[row[:day_of_week].to_i],
          day_number: row[:day_of_week].to_i,
          count: row[:count]
        }
      end

      safe_encode_result(result)
    end

    def get_response_time_stats(db:, address: nil, limit: 50)
      # Analyze response times between emails in threads
      # This is a simplified version - pairs consecutive emails by thread
      query = db[:email].select_all(:email)
      query = query.where(address: address) if address
      query = query.where(Sequel.~(x_gm_thrid: nil))
      query = query.order(:x_gm_thrid, :date)
      query = query.limit(limit * 2) # Get more data to find pairs

      emails = query.all
      response_times = []

      # Group by thread and calculate time differences
      emails.group_by { |e| e[:x_gm_thrid] }.each do |thread_id, thread_emails|
        thread_emails.each_cons(2) do |prev_email, curr_email|
          if prev_email[:date] && curr_email[:date]
            time_diff = (Time.parse(curr_email[:date]) - Time.parse(prev_email[:date])) / 3600.0 # hours
            response_times << {
              thread_id: thread_id,
              from_sender: prev_email[:from],
              to_sender: curr_email[:from],
              response_time_hours: time_diff.round(2),
              prev_date: prev_email[:date],
              curr_date: curr_email[:date]
            }
          end
        end
      end

      # Sort by response time and limit
      result = response_times.sort_by { |rt| rt[:response_time_hours] }.first(limit)
      safe_encode_result(result)
    end

    def get_email_frequency_by_sender(db:, address: nil, sender: nil, period: "monthly", limit: 50)
      # Email frequency patterns per sender over time
      query = db[:email]
      query = query.where(address: address) if address
      query = query.where(Sequel.ilike(:from, "%#{sender}%")) if sender

      date_format = case period.to_s.downcase
      when "daily" then '%Y-%m-%d'
      when "yearly" then '%Y'
      else '%Y-%m' # monthly default
      end

      result = query.select(
        :from,
        Sequel.function(:strftime, date_format, :date).as(:period),
        Sequel.function(:count, Sequel.lit('*')).as(:count)
      ).group(:from, :period).order(:from, :period).limit(limit).all

      safe_encode_result(result)
    end

    def get_seasonal_trends(db:, address: nil, years_back: 3)
      # Email volume trends by month/season over multiple years
      query = db[:email]
      query = query.where(address: address) if address
      
      # Filter to recent years if specified
      if years_back
        cutoff_date = Date.today << (years_back * 12) # Go back N years
        query = query.where { date >= cutoff_date.to_s }
      end

      monthly_data = query.select(
        Sequel.function(:strftime, '%Y', :date).as(:year),
        Sequel.function(:strftime, '%m', :date).as(:month),
        Sequel.function(:count, Sequel.lit('*')).as(:count)
      ).group(:year, :month).order(:year, :month).all

      # Add season classification
      seasons = {
        '12' => 'Winter', '01' => 'Winter', '02' => 'Winter',
        '03' => 'Spring', '04' => 'Spring', '05' => 'Spring',
        '06' => 'Summer', '07' => 'Summer', '08' => 'Summer',
        '09' => 'Fall', '10' => 'Fall', '11' => 'Fall'
      }

      result = monthly_data.map do |row|
        row.merge(
          season: seasons[row[:month]],
          month_name: Date::MONTHNAMES[row[:month].to_i]
        )
      end

      safe_encode_result(result)
    end

    # Advanced Filtering Tools

    def get_emails_by_size_range(db:, address: nil, size_category: "large", limit: 100)
      # Filter emails by size ranges: small (<10KB), medium (10KB-100KB), large (>100KB)
      query = db[:email].select_all(:email)
      query = query.where(address: address) if address

      case size_category.to_s.downcase
      when "small"
        query = query.where { Sequel.function(:length, :encoded) < 10240 } # <10KB
      when "medium"
        query = query.where { (Sequel.function(:length, :encoded) >= 10240) & (Sequel.function(:length, :encoded) < 102400) } # 10KB-100KB  
      when "large"
        query = query.where { Sequel.function(:length, :encoded) >= 102400 } # >100KB
      when "huge"
        query = query.where { Sequel.function(:length, :encoded) >= 1048576 } # >1MB
      else
        # Default to large
        query = query.where { Sequel.function(:length, :encoded) >= 102400 }
      end

      query = query.select_append(Sequel.function(:length, :encoded).as(:size_bytes))
      query = query.order(Sequel.desc(Sequel.function(:length, :encoded)))
      query = query.limit(limit)

      result = query.all.map { |row| symbolize_keys(row.to_h) }
      safe_encode_result(result)
    end

    def get_duplicate_emails(db:, address: nil, similarity_field: "subject", limit: 100)
      # Find potential duplicate emails by subject or message_id similarity
      query = db[:email]
      query = query.where(address: address) if address

      field = similarity_field.to_s == "message_id" ? :message_id : :subject
      
      # Find emails with identical subjects/message_ids
      duplicates = query.select(
        field,
        Sequel.function(:count, Sequel.lit('*')).as(:count),
        Sequel.function(:group_concat, :id).as(:email_ids)
      ).where(Sequel.~(field => nil))
      .group(field)
      .having { count(Sequel.lit('*')) > 1 }
      .order(Sequel.desc(:count))
      .limit(limit)
      .all

      result = duplicates.map do |dup|
        {
          similarity_field => dup[field],
          duplicate_count: dup[:count],
          email_ids: dup[:email_ids]&.split(',')&.map(&:to_i) || []
        }
      end

      safe_encode_result(result)
    end

    def search_email_headers(db:, address: nil, header_pattern: nil, limit: 100)
      # Search through email headers (requires parsing encoded field)
      # This is a simplified version that searches in the raw encoded content
      query = db[:email].select_all(:email)
      query = query.where(address: address) if address
      
      if header_pattern
        # Search in the encoded field (which contains full RFC822 message including headers)
        query = query.where(Sequel.ilike(:encoded, "%#{header_pattern}%"))
      end

      query = query.limit(limit)
      result = query.all.map { |row| symbolize_keys(row.to_h) }
      safe_encode_result(result)
    end

    def get_emails_by_keywords(db:, address: nil, keywords: [], match_mode: "any", limit: 100)
      # Find emails containing specific keywords with frequency scoring
      return safe_encode_result([]) if keywords.empty?

      query = db[:email].select_all(:email)
      query = query.where(address: address) if address

      # Build search conditions
      keyword_conditions = keywords.map do |keyword|
        Sequel.|(Sequel.ilike(:subject, "%#{keyword}%"), Sequel.ilike(:encoded, "%#{keyword}%"))
      end

      if match_mode.to_s.downcase == "all"
        # All keywords must match
        combined_condition = keyword_conditions.reduce { |acc, cond| acc & cond }
      else
        # Any keyword matches (default)
        combined_condition = keyword_conditions.reduce { |acc, cond| acc | cond }
      end

      query = query.where(combined_condition) if combined_condition
      query = query.limit(limit)
      
      emails = query.all.map { |row| symbolize_keys(row.to_h) }

      # Add keyword match scoring
      result = emails.map do |email|
        subject_text = (email[:subject] || "").downcase
        body_text = (email[:encoded] || "").downcase
        
        keyword_matches = keywords.count do |keyword|
          subject_text.include?(keyword.downcase) || body_text.include?(keyword.downcase)
        end

        email.merge(
          keyword_match_count: keyword_matches,
          keyword_match_score: (keyword_matches.to_f / keywords.length * 100).round(1)
        )
      end

      # Sort by match score
      result.sort_by! { |email| -email[:keyword_match_score] }
      safe_encode_result(result)
    end

    # SQL Query Tool (Read-only)

    def execute_sql_query(db:, address: nil, sql_query: nil, limit: 1000)
      return safe_encode_result({error: "SQL query is required"}) if sql_query.nil? || sql_query.strip.empty?
      
      # Security: Only allow SELECT statements and block destructive operations
      normalized_query = sql_query.strip.downcase
      
      # Must start with SELECT or WITH (for CTEs)
      unless normalized_query.start_with?('select') || normalized_query.start_with?('with')
        return safe_encode_result({
          error: "Only SELECT queries and WITH expressions (CTEs) are allowed. Query must start with SELECT or WITH.",
          example: "SELECT * FROM email WHERE subject LIKE '%meeting%' LIMIT 10"
        })
      end
      
      # More precise security check: look for forbidden SQL statements at word boundaries
      # This prevents blocking legitimate searches for emails containing these words
      forbidden_patterns = [
        # Destructive operations that should appear as SQL commands (word boundaries)
        '\binsert\s+into\b', '\bupdate\s+\w+\s+set\b', '\bdelete\s+from\b',
        '\bdrop\s+(table|index|view|database)\b', '\bcreate\s+(table|index|view|database)\b', 
        '\balter\s+table\b', '\btruncate\s+table\b', '\breplace\s+into\b',
        
        # Dangerous pragmas and commands
        '\bpragma\b', '\battach\s+database\b', '\bdetach\s+database\b',
        
        # Transaction commands
        '\bbegin\s+(transaction|immediate|exclusive)\b', '\bcommit\b', '\brollback\b',
        '\bsavepoint\b', '\brelease\s+savepoint\b'
      ]
      
      forbidden_patterns.each do |pattern|
        if normalized_query.match(/#{pattern}/i)
          matched_text = normalized_query.match(/#{pattern}/i)[0]
          return safe_encode_result({
            error: "Forbidden SQL operation detected: '#{matched_text}'. Only SELECT queries are allowed.",
            allowed_operations: ["SELECT", "WITH (for CTEs)"],
            note: "Searches for emails containing these words in content are allowed, but SQL commands are blocked."
          })
        end
      end
      
      # Add LIMIT clause if not present to prevent runaway queries
      unless normalized_query.include?('limit')
        sql_query += " LIMIT #{limit}"
      end
      
      begin
        # Execute the query
        result = db.fetch(sql_query).all
        
        # Convert to hash array and ensure encoding safety
        rows = result.map { |row| symbolize_keys(row.to_h) }
        
        response = {
          query: sql_query,
          row_count: rows.length,
          rows: rows
        }
        
        safe_encode_result(response)
        
      rescue Sequel::DatabaseError => e
        safe_encode_result({
          error: "SQL execution error: #{e.message}",
          query: sql_query,
          hint: "Check your SQL syntax. Remember: only SELECT queries are allowed."
        })
      rescue => e
        safe_encode_result({
          error: "Unexpected error: #{e.message}",
          query: sql_query
        })
      end
    end

    # Helpers
    def symbolize_keys(h)
      h.each_with_object({}) do |(k, v), m|
        key = (k.is_a?(Symbol) ? k : k.to_s.downcase.to_sym)

        # Fix encoding issues with string values
        value = if v.is_a?(String)
          # Force encoding to UTF-8, replacing invalid characters
          v.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
        else
          v
        end

        m[key] = value
      end
    end

    # Encoding safety wrapper for all query results
    def safe_encode_result(data)
      case data
      when Array
        data.map { |item| safe_encode_result(item) }
      when Hash
        data.each_with_object({}) do |(k, v), result|
          result[k] = safe_encode_result(v)
        end
      when String
        data.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
      else
        data
      end
    end

    def sql_in_list(arr)
      # Simple safe literal for small enums
      items = arr.map { |s| "'#{s.gsub("'", "''")}'" }.join(",")
      "(#{items})"
    end
  end
end
