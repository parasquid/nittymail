# frozen_string_literal: true

require "thor"
require "time"
require_relative "../utils/utils"
require_relative "../utils/db"
require_relative "../utils/enricher"

module NittyMail
  module Commands
    class DB < Thor
      desc "latest", "Show the latest (by INTERNALDATE) email in the collection"
      method_option :uidvalidity, type: :numeric, required: false, desc: "UIDVALIDITY generation (if omitted, attempt to infer || list options)"
      method_option :mailbox, aliases: "-m", type: :string, default: "INBOX", desc: "Mailbox name (for default collection)"
      method_option :collection, type: :string, required: false, desc: "Chroma collection name (defaults to address+mailbox)"
      method_option :address, aliases: "-a", type: :string, required: false, desc: "Account email (or env NITTYMAIL_IMAP_ADDRESS)"
      method_option :limit, type: :numeric, default: 2000, desc: "Max rows to scan when inferring uidvalidity"
      method_option :page_size, type: :numeric, default: 200, desc: "Page size for sampling"
      def latest
        mailbox = options[:mailbox] || "INBOX"
        address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
        limit = Integer(options[:limit])
        page_size = Integer(options[:page_size])

        if address.to_s.empty?
          raise ArgumentError, "missing account: pass --address || set NITTYMAIL_IMAP_ADDRESS"
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
          rescue => e
            warn "latest: error sampling uidvalidity candidates: #{e.class}: #{e.message}"
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

        max_epoch = find_max_internaldate_epoch(collection, uidvalidity: uidvalidity)
        if !max_epoch || max_epoch <= 0
          warn "no documents with internaldate_epoch found for uidvalidity=#{uidvalidity} in collection '#{collection_name}'"
          exit 2
        end

        candidates = collection.get(
          page: 1,
          page_size: 10,
          where: {'$and': [
            {uidvalidity: uidvalidity},
            {internaldate_epoch: max_epoch}
          ]}
        )
        if candidates.empty?
          window = 86_400
          near = collection.get(
            page: 1,
            page_size: 200,
            where: {'$and': [
              {uidvalidity: uidvalidity},
              {internaldate_epoch: {'$gt': max_epoch - window, '$lte': max_epoch}}
            ]}
          )
          if near.empty?
            warn "no document found at computed max internaldate_epoch=#{max_epoch}"
            exit 2
          end
          best = near.max_by do |e|
            md = e.respond_to?(:metadata) ? e.metadata : nil
            (md && (md["internaldate_epoch"] || md[:internaldate_epoch]) || 0).to_i
          end
          print_document(best)
        else
          print_document(candidates.first)
        end
      end

      desc "stats", "Show collection stats (per uidvalidity)"
      method_option :uidvalidity, type: :string, required: false, desc: "Comma-separated uidvalidity values to include"
      method_option :mailbox, aliases: "-m", type: :string, default: "INBOX", desc: "Mailbox name (for default collection)"
      method_option :collection, type: :string, required: false, desc: "Chroma collection name (defaults to address+mailbox)"
      method_option :address, aliases: "-a", type: :string, required: false, desc: "Account email (or env NITTYMAIL_IMAP_ADDRESS)"
      method_option :page_size, type: :numeric, default: 500, desc: "Page size for scanning"
      def stats
        mailbox = options[:mailbox] || "INBOX"
        address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
        page_size = Integer(options[:page_size])
        if address.to_s.empty?
          raise ArgumentError, "missing account: pass --address || set NITTYMAIL_IMAP_ADDRESS"
        end
        collection, collection_name = collection_for(address: address, mailbox: mailbox, override: options[:collection])
        gens_filter = options[:uidvalidity] && options[:uidvalidity].to_s.split(",").map { |v| v.strip.to_i }

        stats = Hash.new { |h, k| h[k] = {count: 0, min_uid: nil, max_uid: nil, min_epoch: nil, max_epoch: nil, size_sum: 0, min_size: nil, max_size: nil, sender_counts: Hash.new(0), label_counts: Hash.new(0)} }
        page = 1
        begin
          loop do
            embeddings = collection.get(page: page, page_size: page_size)
            break if embeddings.empty?
            embeddings.each do |e|
              md = e.respond_to?(:metadata) ? e.metadata : {}
              gen = md[:uidvalidity] || md["uidvalidity"] || e.id.to_s.split(":", 2)[0].to_i
              next if gens_filter && !gens_filter.include?(gen)
              uid = e.id.to_s.split(":", 2)[1].to_i
              epoch = (md && (md["internaldate_epoch"] || md[:internaldate_epoch]) || 0).to_i
              st = stats[gen]
              st[:count] += 1
              st[:min_uid] = uid if st[:min_uid].nil? || uid < st[:min_uid]
              st[:max_uid] = uid if st[:max_uid].nil? || uid > st[:max_uid]
              st[:min_epoch] = epoch if st[:min_epoch].nil? || epoch < st[:min_epoch]
              st[:max_epoch] = epoch if st[:max_epoch].nil? || epoch > st[:max_epoch]
              size = (md && (md["rfc822_size"] || md[:rfc822_size]) || 0).to_i
              st[:size_sum] += size
              st[:min_size] = size if st[:min_size].nil? || size < st[:min_size]
              st[:max_size] = size if st[:max_size].nil? || size > st[:max_size]
              sender = (md && (md["from_email"] || md[:from_email]) || "").to_s.downcase
              st[:sender_counts][sender] += 1 unless sender.empty?
              Array(md && (md["labels"] || md[:labels]) || []).each do |lab|
                st[:label_counts][lab.to_s] += 1
              end
            end
            break if embeddings.size < page_size
            page += 1
          end
        rescue => e
          warn "error scanning collection '#{collection_name}': #{e.class}: #{e.message}"
          exit 4
        end

        if stats.empty?
          puts "(no records)"
          return
        end

        puts "Collection: #{collection_name}"
        stats.keys.sort.each do |gen|
          st = stats[gen]
          puts "uidvalidity: #{gen}"
          puts "  records: #{st[:count]}"
          if st[:count] > 0
            puts "  uid range: #{st[:min_uid]}..#{st[:max_uid]}"
            puts "  internaldate_epoch max: #{st[:max_epoch]} (#{Time.at(st[:max_epoch]).utc})"
            puts "  internaldate_epoch min: #{st[:min_epoch]} (#{Time.at(st[:min_epoch]).utc})"
            avg = (st[:size_sum].to_f / st[:count]).round(1)
            puts "  size bytes: min=#{st[:min_size]} max=#{st[:max_size]} avg=#{avg} sum=#{st[:size_sum]}"
            top_senders = st[:sender_counts].sort_by { |_, c| -c }.first(5)
            unless top_senders.empty?
              puts "  top senders:"
              top_senders.each { |email, c| puts "    #{email} (#{c})" }
            end
            top_labels = st[:label_counts].sort_by { |_, c| -c }.first(5)
            unless top_labels.empty?
              puts "  top labels:"
              top_labels.each { |lab, c| puts "    #{lab} (#{c})" }
            end
          end
        end
      end

      desc "backfill", "Backfill subject/plain/markdown embeddings for existing raw documents"
      method_option :uidvalidity, type: :numeric, required: false, desc: "Process only this UIDVALIDITY"
      method_option :mailbox, aliases: "-m", type: :string, default: "INBOX", desc: "Mailbox name (for default collection)"
      method_option :collection, type: :string, required: false, desc: "Chroma collection name (defaults to address+mailbox)"
      method_option :address, aliases: "-a", type: :string, required: false, desc: "Account email (or env NITTYMAIL_IMAP_ADDRESS)"
      method_option :page_size, type: :numeric, default: 200, desc: "Page size for scanning"
      method_option :batch_size, type: :numeric, default: 100, desc: "Upload batch size"
      method_option :skip_errors, type: :boolean, default: false, desc: "Skip messages that fail to parse or convert"
      def backfill
        mailbox = options[:mailbox] || "INBOX"
        address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
        page_size = Integer(options[:page_size])
        batch_size = Integer(options[:batch_size])
        if address.to_s.empty?
          raise ArgumentError, "missing account: pass --address or set NITTYMAIL_IMAP_ADDRESS"
        end
        collection, collection_name = collection_for(address: address, mailbox: mailbox, override: options[:collection])
        uv = options[:uidvalidity] && Integer(options[:uidvalidity])

        # First pass: count total raw docs
        total = 0
        cpage = 1
        loop do
          cemb = if uv
            collection.get(page: cpage, page_size: page_size, where: {'$and': [{uidvalidity: uv}, {item_type: "raw"}]})
          else
            collection.get(page: cpage, page_size: page_size)
          end
          break if cemb.empty?
          total += cemb.count { |e| (e.respond_to?(:metadata) ? (e.metadata[:item_type] || e.metadata["item_type"]) : nil) == "raw" || e.id.to_s.split(":").length == 2 }
          break if cemb.size < page_size
          cpage += 1
        end

        processed = 0
        progress = NittyMail::Utils.progress_bar(title: "Backfill", total: total)
        added = 0
        page = 1
        loop do
          embeddings = if uv
            collection.get(page: page, page_size: page_size, where: {'$and': [{uidvalidity: uv}, {item_type: "raw"}]})
          else
            collection.get(page: page, page_size: page_size)
          end
          break if embeddings.empty?
          raw_docs = embeddings.select do |e|
            md = e.respond_to?(:metadata) ? e.metadata : {}
            item_type = md[:item_type] || md["item_type"]
            item_type == "raw" || e.id.to_s.split(":").length == 2
          end

          begin
            ids, docs, metas = backfill_variants(collection, raw_docs, strict: !options[:skip_errors])
          rescue => e
            warn "backfill error: %s: %s" % [e.class, e.message]
            raise unless options[:skip_errors]
            ids = docs = metas = []
          end
          existing = NittyMail::Workers::Chroma.existing_ids(collection: collection, candidate_ids: ids, threads: 4, batch_size: 1000)
          to_add = []
          ids.each_with_index do |idv, idx|
            next if existing.include?(idv)
            to_add << [idv, docs[idx], metas[idx]]
          end
          # Update progress bar title with live status
          begin
            progress.title = "Backfill add:%d page:%d rq:%d added:%d" % [to_add.size, page, raw_docs.size, added]
          rescue
          end

          to_add.each_slice(batch_size) do |chunk|
            embeddings_objs = chunk.map do |idv, doc, meta|
              norm_doc = NittyMail::Enricher.normalize_utf8(doc)
              norm_meta = normalize_meta(meta)
              ::Chroma::Resources::Embedding.new(id: idv, document: norm_doc, metadata: norm_meta)
            end
            collection.add(embeddings_objs)
            added += embeddings_objs.size
          end
          processed += raw_docs.size
          progress.progress = [processed, total].min
          break if embeddings.size < page_size
          page += 1
        end
        progress.finish unless progress.finished?
        puts "Backfill complete for '#{collection_name}': processed=#{processed}, added=#{added}"
      rescue ::Chroma::ChromaError => e
        warn "chroma error: #{e.class}: #{e.message}"
        exit 4
      rescue => e
        warn "unexpected error: #{e.class}: #{e.message}"
        exit 5
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
          raise ArgumentError, "missing account: pass --address || set NITTYMAIL_IMAP_ADDRESS"
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
        def normalize_meta(meta)
          out = {}
          meta.to_h.each do |k, v|
            out[k] = case v
            when String
              NittyMail::Enricher.normalize_utf8(v)
            when Array
              v.map { |x| x.is_a?(String) ? NittyMail::Enricher.normalize_utf8(x) : x }
            else
              v
            end
          end
          out
        end

        def backfill_variants(collection, entries, strict: true)
          ids = []
          docs = []
          metas = []
          entries.each do |e|
            raw = e.respond_to?(:document) ? e.document : nil
            next if raw.to_s.empty?
            md = e.respond_to?(:metadata) ? e.metadata : {}
            uidvalidity = md[:uidvalidity] || md["uidvalidity"] || e.id.to_s.split(":", 2)[0].to_i
            uid = e.id.to_s.split(":", 2)[1].to_i
            base_meta = {
              address: md[:address] || md["address"],
              mailbox: md[:mailbox] || md["mailbox"],
              uidvalidity: uidvalidity,
              uid: uid,
              internaldate_epoch: (md[:internaldate_epoch] || md["internaldate_epoch"]).to_i,
              from_email: (md[:from_email] || md["from_email"]).to_s,
              rfc822_size: (md[:rfc822_size] || md["rfc822_size"] || raw.to_s.bytesize).to_i,
              labels: Array(md[:labels] || md["labels"] || []),
              item_type: "raw"
            }
            v_ids, v_docs, v_metas = NittyMail::Enricher.variants_for(raw: raw, base_meta: base_meta, uidvalidity: uidvalidity, uid: uid, raise_on_error: strict)
            ids.concat(v_ids)
            docs.concat(v_docs)
            metas.concat(v_metas)
          end
          [ids, docs, metas]
        end

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

        def find_max_internaldate_epoch(collection, uidvalidity:)
          low = 0
          high = Time.now.to_i + 31_556_952
          exists = lambda do |ts|
            res = collection.get(
              page: 1,
              page_size: 1,
              where: {'$and': [
                {uidvalidity: uidvalidity},
                {internaldate_epoch: {'$gte': ts}}
              ]}
            )
            !res.empty?
          rescue
            false
          end
          return nil unless exists.call(0)
          while low < high
            mid = (low + high + 1) / 2
            if exists.call(mid)
              low = mid
            else
              high = mid - 1
            end
          end
          low
        end

        def suggest_neighbor_uids(collection, uidvalidity:, uid:, window: 10)
          neighbors = ((uid - window)..(uid + window)).to_a - [uid]
          ids = neighbors.map { |u| "#{uidvalidity}:#{u}" }
          begin
            hits = collection.get(ids: ids)
            uids = hits.map(&:id).map { |did| did.split(":", 2)[1].to_i }
            neighbors.select { |u| uids.include?(u) }
          rescue => e
            warn "neighbor uid suggestion failed: #{e.class}: #{e.message}"
            []
        end
      end
      end
    end
  end
end
