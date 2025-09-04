# frozen_string_literal: true

require "thor"
require_relative "../utils/utils"
require_relative "../utils/db"

module NittyMail
  module Commands
    class DB < Thor
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

        safe_mbox = mailbox.to_s
        default_collection = NittyMail::Utils.sanitize_collection_name("nittymail-#{address}-#{safe_mbox}")
        collection_name = options[:collection] || default_collection

        collection = NittyMail::DB.chroma_collection(collection_name)

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

        puts "Multiple UIDVALIDITY generations found for uid: #{uid}: #{gens.join(", ")}"
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
