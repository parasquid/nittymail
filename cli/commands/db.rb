# frozen_string_literal: true

require "thor"
require "time"
require_relative "../utils/utils"
require_relative "../utils/db"

module NittyMail
  module Commands
    class DB < Thor
      desc "latest", "Show the latest (by Date header) email in the collection"
      method_option :uidvalidity, type: :numeric, required: false, desc: "UIDVALIDITY generation (if omitted, attempt to infer or list options)"
      method_option :mailbox, aliases: "-m", type: :string, default: "INBOX", desc: "Mailbox name (for default collection)"
      method_option :collection, type: :string, required: false, desc: "Chroma collection name (defaults to address+mailbox)"
      method_option :address, aliases: "-a", type: :string, required: false, desc: "Account email (or env NITTYMAIL_IMAP_ADDRESS)"
      method_option :limit, type: :numeric, default: 2000, desc: "Max rows to scan when inferring latest"
      method_option :page_size, type: :numeric, default: 200, desc: "Page size for scanning"
      def latest
        mailbox = options[:mailbox] || "INBOX"
        address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
        limit = Integer(options[:limit])
        page_size = Integer(options[:page_size])

        if address.to_s.empty?
          raise ArgumentError, "missing account: pass --address or set NITTYMAIL_IMAP_ADDRESS"
        end

        collection, collection_name = collection_for(address: address, mailbox: mailbox, override: options[:collection])

        uidvalidity = options[:uidvalidity] && Integer(options[:uidvalidity])
        if uidvalidity.nil?
          gens = []
          page = 1
          sampled = 0
          begin
            loop do
              embeddings = collection.get(page: page, page_size: page_size)
              break if embeddings.empty?
              gens.concat(
                embeddings.map do |e|
                  md = e.respond_to?(:metadata) ? e.metadata : nil
                  md && (md[:uidvalidity] || md["uidvalidity"]) || e.id.to_s.split(":", 2)[0].to_i
                end
              )
              sampled += embeddings.size
              page += 1
              break if sampled >= [limit, page_size * 5].max
              break if embeddings.size < page_size
            end
          rescue
            gens = []
          end
          gens = gens.compact.uniq.sort
          if gens.size == 1
            uidvalidity = gens.first
          else
            warn "Cannot determine a single UIDVALIDITY for collection '#{collection_name}'."
            puts "Possible UIDVALIDITY values: #{gens.join(", ")}" unless gens.empty?
            puts "Re-run with: --uidvalidity <n>"
            exit 3
          end
        end

        newest = nil
        newest_time = Time.at(0)
        scanned = 0
        page = 1
        begin
          loop do
            embeddings = collection.get(page: page, page_size: page_size, where: {uidvalidity: uidvalidity})
            break if embeddings.empty?
            embeddings.each do |e|
              t = parse_date_header(e.respond_to?(:document) ? e.document : nil)
              if t && t > newest_time
                newest_time = t
                newest = e
              end
            end
            scanned += embeddings.size
            break if scanned >= limit
            break if embeddings.size < page_size
            page += 1
          end
        rescue
          warn "failed to scan collection '#{collection_name}' for latest; try lowering --page_size or increasing --limit"
          exit 4
        end

        if newest.nil?
          warn "no documents found for uidvalidity=#{uidvalidity} in collection '#{collection_name}'"
          exit 2
        end

        print_document(newest)
      end

      desc "show", "Show a previously fetched email by UID"
      method_option :uid, type: :numeric, required: true, desc: "IMAP UID of the message"
      method_option :uidvalidity, type: :numeric, required: false, desc: "UIDVALIDITY generation (if omitted, show possible values from DB)"
      method_option :mailbox, aliases: "-m", type: :string, default: "INBOX", desc: "Mailbox name (for default collection)"
      method_option :collection, type: :string, required: false, desc: "Chroma collection name (defaults to address+mailbox)"
      method_option :address, aliases: "-a", type: :string, required: false, desc: "Account email (or env NITTYMAIL_IMAP_ADDRESS)"
      def show
        uid = Integer(options[:uid])
        mailbox = options[:mailbox] || "INBOX"
        address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]

        if address.to_s.empty?
          raise ArgumentError, "missing account: pass --address or set NITTYMAIL_IMAP_ADDRESS"
        end

        collection, collection_name = collection_for(address: address, mailbox: mailbox, override: options[:collection])

        if options[:uidvalidity]
          uidvalidity = Integer(options[:uidvalidity])
          id = "#{uidvalidity}:#{uid}"
          embeddings = collection.get(ids: [id])
          if embeddings.empty?
            warn "not found: id=#{id} in collection '#{collection_name}'"
            suggestions = suggest_neighbor_uids(collection, uidvalidity: uidvalidity, uid: uid, window: 10)
            unless suggestions.empty?
              puts "Nearby existing UIDs for uidvalidity=#{uidvalidity}: #{suggestions.join(", ")}"
            end
            exit 2
          end
          print_document(embeddings.first)
          return
        end

        # Discover possible UIDVALIDITY values for this UID
        possible = []
        page = 1
        page_size = 200
        begin
          loop do
            embeddings = collection.get(page: page, page_size: page_size, where: {uid: uid})
            break if embeddings.empty?
            possible.concat(embeddings)
            break if embeddings.size < page_size
            page += 1
          end
        rescue
          # If server-side where fails, don't scan whole collection; ask user for uidvalidity
          warn "uidvalidity not provided. Possible generations cannot be determined without metadata filtering."
          warn "please re-run with --uidvalidity <n>"
          exit 3
        end

        if possible.empty?
          warn "no documents found for uid=#{uid} in collection '#{collection_name}'"
          puts "Tip: Re-run with --uidvalidity <n> to get neighbor suggestions."
          exit 2
        end

        gens = possible.map { |e| (e.respond_to?(:metadata) ? e.metadata[:uidvalidity] || e.metadata["uidvalidity"] : nil) || e.id.to_s.split(":", 2)[0].to_i }.uniq.sort
        if gens.size == 1
          id = "#{gens.first}:#{uid}"
          embed = possible.find { |e| e.id == id } || possible.first
          print_document(embed)
          return
        end

        puts "Multiple UIDVALIDITY generations found for uid=#{uid}: #{gens.join(", ")}"
        puts "Re-run with: --uidvalidity <one of: #{gens.join(", ")}>"
      rescue ArgumentError => e
        warn "error: #{e.message}"
        exit 1
      rescue ::Chroma::ChromaError => e
        warn "chroma error: #{e.class}: #{e.message}"
        exit 4
      rescue => e
        warn "unexpected error: #{e.class}: #{e.message}"
        exit 5
      end

      no_commands do
        def print_document(embedding)
          doc = embedding.respond_to?(:document) ? embedding.document : nil
          if doc.to_s.empty?
            warn "document payload missing for id=#{embedding.id}"
            exit 6
          end
          puts doc
        end

        def collection_for(address:, mailbox:, override: nil)
          safe_mbox = mailbox.to_s
          default_collection = NittyMail::Utils.sanitize_collection_name("nittymail-#{address}-#{safe_mbox}")
          name = override || default_collection
          [NittyMail::DB.chroma_collection(name), name]
        end

        def parse_date_header(rfc822)
          line = rfc822.to_s.each_line.find { |l| l.start_with?("Date:") }
          return Time.at(0) unless line
          Time.parse(line.sub(/^Date:\s*/i, "").strip)
        rescue
          Time.at(0)
        end

        def suggest_neighbor_uids(collection, uidvalidity:, uid:, window: 10)
          neighbors = ((uid - window)..(uid + window)).to_a - [uid]
          ids = neighbors.map { |u| "#{uidvalidity}:#{u}" }
          begin
            hits = collection.get(ids: ids)
            uids = hits.map(&:id).map { |did| did.split(":", 2)[1].to_i }
            neighbors.select { |u| uids.include?(u) }
          rescue
            []
          end
        end
      end
    end
  end
end
