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
                "id" => {"type" => "integer"},
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
        }
      ]
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
