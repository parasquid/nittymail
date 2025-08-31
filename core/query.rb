# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "lib/nittymail/db"
require_relative "lib/nittymail/embeddings"
require_relative "lib/nittymail/query_tools"

module NittyMail
  module Query
    class Settings
      attr_accessor :database_path, :address, :ollama_host, :model, :prompt,
        :default_limit, :quiet, :debug

      DEFAULTS = {
        default_limit: 100,
        quiet: false,
        debug: false
      }.freeze

      def initialize(**options)
        required = [:database_path, :address, :ollama_host, :model, :prompt]
        missing = required - options.keys
        raise ArgumentError, "Missing required options: #{missing.join(", ")}" unless missing.empty?
        DEFAULTS.merge(options).each { |key, value| instance_variable_set("@#{key}", value) }
      end
    end

    module_function

    # Orchestrates a single-turn (with tools) chat to answer a prompt.
    # - Uses Ollama chat API with tools for DB access and vector search.
    # - If the model does not call tools, returns its text.
    # - Caps at a few tool/response iterations to avoid loops.
    def perform(settings)
      db = NittyMail::DB.connect(settings.database_path, wal: true, load_vec: true)
      NittyMail::DB.ensure_schema!(db)

      tools = NittyMail::QueryTools.tool_schemas

      messages = []
      messages << {
        role: "system",
        content: [
          "You are an assistant that answers questions about a Gmail mailbox stored in a SQLite database.",
          "Always use provided tools to fetch facts. If a limit is not specified in the user's request, default to #{settings.default_limit}.",
          "Schema: table email(id, address, mailbox, uid, uidvalidity, message_id, date, from, subject, has_attachments, x_gm_labels, x_gm_msgid, x_gm_thrid, flags, encoded).",
          "Vector search: email_vec + email_vec_meta join to email via (email_vec_meta.email_id). You can find emails about a topic by using the vector search tool with the user's query text.",
          (settings.address ? "Current address context: #{settings.address}. Prefer filtering to this address when reasonable." : nil)
        ].compact.join(" ")
      }
      messages << {role: "user", content: settings.prompt.to_s}

      itr = 0
      begin
        loop do
          itr += 1
          raise "tool loop exceeded (#{itr}/6 iterations)" if itr > 6

          resp = chat_request(ollama_host: settings.ollama_host, model: settings.model, messages: messages, tools: tools, debug: settings.debug)
          msg = resp.dig("message") || {}
          tool_calls = msg["tool_calls"] || []

          if tool_calls.empty?
            # No tool use; return assistant content
            content = msg["content"].to_s
            text = content.empty? ? resp["response"].to_s : content
            if text.strip.empty?
              return "No response from model. Please try rephrasing your query."
            end
            return text
          end

          # Record the assistant's tool request in the transcript for context
          messages << {role: "assistant", tool_calls: tool_calls, content: msg["content"].to_s}

          tool_calls.each do |tc|
            name = tc.dig("function", "name") || tc["name"]
            args = tc.dig("function", "arguments") || tc["arguments"] || {}
            args = ensure_hash(args)
            # Enforce default limit when not provided
            args["limit"] = settings.default_limit if args["limit"].to_i <= 0

            if settings.debug
              puts "=== DEBUG: Executing Tool Call ==="
              puts "Tool: #{name}"
              puts "Args: #{args.inspect}"
            end

            if name == "db.list_earliest_emails"
              result = NittyMail::QueryTools.list_earliest_emails(db: db, address: settings.address, limit: args["limit"].to_i)
              if settings.debug
                puts "Result count: #{result.length}"
                begin
                  json_content = JSON.generate(result)
                  puts "JSON serialization: OK (#{json_content.length} bytes)"
                rescue => e
                  puts "JSON serialization ERROR: #{e.message}"
                  puts "Problematic result: #{result.inspect[0..500]}..."
                end
              end
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_email_full"
              result = NittyMail::QueryTools.get_email_full(
                db: db,
                address: settings.address,
                id: args["id"],
                mailbox: args["mailbox"],
                uid: args["uid"],
                uidvalidity: args["uidvalidity"],
                message_id: args["message_id"],
                from_contains: args["from_contains"],
                subject_contains: args["subject_contains"],
                date: args["date"],
                order: args["order"]
              )
              messages << {role: "tool", name: name, content: JSON.generate(result || {})}
            elsif name == "db.filter_emails"
              result = NittyMail::QueryTools.filter_emails(
                db: db,
                address: settings.address,
                from_contains: args["from_contains"],
                from_domain: args["from_domain"],
                subject_contains: args["subject_contains"],
                mailbox: args["mailbox"],
                date_from: args["date_from"],
                date_to: args["date_to"],
                order: args["order"],
                limit: args["limit"].to_i
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.search_emails"
              query = (args["query"] || args["text"] || "").to_s
              item_types = args["item_types"] || ["subject", "body"]
              result = NittyMail::QueryTools.search_emails(
                db: db,
                query: query,
                item_types: item_types,
                limit: args["limit"].to_i,
                ollama_host: settings.ollama_host
              )
              if settings.debug
                puts "Search result count: #{result.length}"
                begin
                  json_content = JSON.generate(result)
                  puts "JSON serialization: OK (#{json_content.length} bytes)"
                rescue => e
                  puts "JSON serialization ERROR: #{e.message}"
                  puts "Checking each result..."
                  result.each_with_index do |row, i|
                    JSON.generate(row)
                  rescue => row_error
                    puts "  Row #{i} (ID: #{begin
                      row[:id]
                    rescue
                      "unknown"
                    end}) ERROR: #{row_error.message}"
                    row.each do |field, value|
                      next unless value.is_a?(String)
                      begin
                        JSON.generate({field => value})
                      rescue
                        puts "    Problematic field: #{field}"
                        puts "      Encoding: #{value.encoding}"
                        puts "      Valid?: #{value.valid_encoding?}"
                        puts "      Value: #{value.inspect[0..100]}..."
                      end
                    end
                  end
                end
              end
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.count_emails"
              count = NittyMail::QueryTools.count_emails(
                db: db,
                address: settings.address,
                from_contains: args["from_contains"],
                from_domain: args["from_domain"],
                subject_contains: args["subject_contains"],
                mailbox: args["mailbox"],
                date_from: args["date_from"],
                date_to: args["date_to"]
              )
              if settings.debug
                puts "Count result: #{count}"
                begin
                  json_content = JSON.generate({count: count})
                  puts "JSON serialization: OK (#{json_content.length} bytes)"
                rescue => e
                  puts "JSON serialization ERROR: #{e.message}"
                  puts "Count value: #{count.inspect}"
                end
              end
              messages << {role: "tool", name: name, content: JSON.generate({count: count})}
            elsif name == "db.get_email_stats"
              result = NittyMail::QueryTools.get_email_stats(
                db: db,
                address: settings.address,
                top_limit: args["top_limit"] || 10
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_top_senders"
              result = NittyMail::QueryTools.get_top_senders(
                db: db,
                address: settings.address,
                limit: args["limit"] || 20,
                mailbox: args["mailbox"]
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_top_domains"
              result = NittyMail::QueryTools.get_top_domains(
                db: db,
                address: settings.address,
                limit: args["limit"] || 20
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_mailbox_stats"
              result = NittyMail::QueryTools.get_mailbox_stats(
                db: db,
                address: address
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_emails_by_date_range"
              result = NittyMail::QueryTools.get_emails_by_date_range(
                db: db,
                address: settings.address,
                period: args["period"] || "monthly",
                date_from: args["date_from"],
                date_to: args["date_to"],
                limit: args["limit"] || 50
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_emails_with_attachments"
              result = NittyMail::QueryTools.get_emails_with_attachments(
                db: db,
                address: settings.address,
                mailbox: args["mailbox"],
                date_from: args["date_from"],
                date_to: args["date_to"],
                limit: args["limit"] || 100
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_email_thread"
              result = NittyMail::QueryTools.get_email_thread(
                db: db,
                address: settings.address,
                thread_id: args["thread_id"],
                order: args["order"] || "date_asc"
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_email_activity_heatmap"
              result = NittyMail::QueryTools.get_email_activity_heatmap(
                db: db,
                address: settings.address,
                date_from: args["date_from"],
                date_to: args["date_to"]
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_response_time_stats"
              result = NittyMail::QueryTools.get_response_time_stats(
                db: db,
                address: settings.address,
                limit: args["limit"] || 50
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_email_frequency_by_sender"
              result = NittyMail::QueryTools.get_email_frequency_by_sender(
                db: db,
                address: settings.address,
                sender: args["sender"],
                period: args["period"] || "monthly",
                limit: args["limit"] || 50
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_seasonal_trends"
              result = NittyMail::QueryTools.get_seasonal_trends(
                db: db,
                address: settings.address,
                years_back: args["years_back"] || 3
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_emails_by_size_range"
              result = NittyMail::QueryTools.get_emails_by_size_range(
                db: db,
                address: settings.address,
                size_category: args["size_category"] || "large",
                limit: args["limit"] || 100
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_duplicate_emails"
              result = NittyMail::QueryTools.get_duplicate_emails(
                db: db,
                address: settings.address,
                similarity_field: args["similarity_field"] || "subject",
                limit: args["limit"] || 100
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.search_email_headers"
              result = NittyMail::QueryTools.search_email_headers(
                db: db,
                address: settings.address,
                header_pattern: args["header_pattern"],
                limit: args["limit"] || 100
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.get_emails_by_keywords"
              result = NittyMail::QueryTools.get_emails_by_keywords(
                db: db,
                address: settings.address,
                keywords: args["keywords"] || [],
                match_mode: args["match_mode"] || "any",
                limit: args["limit"] || 100
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            elsif name == "db.execute_sql_query"
              result = NittyMail::QueryTools.execute_sql_query(
                db: db,
                address: settings.address,
                sql_query: args["sql_query"],
                limit: args["limit"] || 1000
              )
              messages << {role: "tool", name: name, content: JSON.generate(result)}
            else
              messages << {role: "tool", name: name.to_s, content: JSON.generate({error: "unknown tool"})}
            end
          end

          # Ask model to synthesize final answer from tool outputs
          messages << {role: "system", content: "Use the tool results above to answer clearly with a concise list or summary."}
        end
      rescue => e
        # Return a clear error message for any failures
        "Query failed: #{e.message}. Please ensure Ollama is running and the model supports tools."
      end
    ensure
      db&.disconnect
    end

    def chat_request(ollama_host:, model:, messages:, tools: nil, debug: false)
      raise ArgumentError, "ollama_host is required" if ollama_host.nil? || ollama_host.strip.empty?
      uri = URI.parse(File.join(ollama_host, "/api/chat"))
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      body = {model: model, messages: messages, stream: false}
      body[:tools] = tools if tools && !tools.empty?

      # Debug logging for request
      if settings.debug
        puts "=== DEBUG: Ollama Request ==="
        puts "URL: #{uri}"
        puts "Model: #{model}"
        puts "Messages: #{messages.length} messages"
        puts "Tools: #{tools ? tools.length : 0} tools"

        # Log the request payload, but truncate if too long
        request_json = JSON.generate(body)
        if request_json.length > 2000
          puts "Request JSON (first 2000 chars): #{request_json[0..2000]}..."
        else
          puts "Request JSON: #{request_json}"
        end
        puts "Request size: #{request_json.length} bytes"

        # Check for encoding issues in the request
        begin
          request_json.encode("UTF-8")
          puts "Request encoding: OK"
        rescue => e
          puts "Request encoding ERROR: #{e.message}"
        end
        puts "=============================="
      end

      req.body = JSON.generate(body)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")

      # Make request and log response
      res = http.request(req)

      if settings.debug
        puts "=== DEBUG: Ollama Response ==="
        puts "HTTP Status: #{res.code} #{res.message}"
        puts "Response size: #{res.body.length} bytes"

        if res.body.length > 2000
          puts "Response body (first 2000 chars): #{res.body[0..2000]}..."
        else
          puts "Response body: #{res.body}"
        end

        # Check for encoding issues in the response
        begin
          res.body.encode("UTF-8")
          puts "Response encoding: OK"
        rescue => e
          puts "Response encoding ERROR: #{e.message}"
          puts "Response bytes: #{res.body.bytes[0..50].map { |b| '\\x%02X' % b }.join}"
        end
        puts "=============================="
      end

      unless res.is_a?(Net::HTTPSuccess)
        raise "ollama chat HTTP #{res.code}: #{res.body}"
      end

      JSON.parse(res.body)
    end

    def ensure_hash(obj)
      return obj if obj.is_a?(Hash)
      JSON.parse(obj.to_s)
    rescue
      {}
    end
  end
end
