#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "thor"
require "json"
require "uri"
require "net/http"
require "nitty_mail"
require "chroma-db"
require "ruby-progressbar"

module NittyMail
  class CLI < Thor
    # Removed custom Chroma client in favor of the official gem `chroma-db`.
    # Subcommand: mailbox
    class MailboxCmd < Thor
      desc "list", "List all mailboxes for the account"
      method_option :address, aliases: "-a", type: :string, required: false, desc: "IMAP account (email) (or env NITTYMAIL_IMAP_ADDRESS)"
      method_option :password, aliases: "-p", type: :string, required: false, desc: "IMAP password / app password (or env NITTYMAIL_IMAP_PASSWORD)"
      def list
        address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
        password = options[:password] || ENV["NITTYMAIL_IMAP_PASSWORD"]

        if address.to_s.empty? || password.to_s.empty?
          raise ArgumentError, "missing credentials: pass --address/--password or set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD"
        end

        settings = NittyMail::Settings.new(imap_address: address, imap_password: password)
        mb = NittyMail::Mailbox.new(settings: settings)
        list = Array(mb.list)

        names = list.map { |x| x.respond_to?(:name) ? x.name : x.to_s }

        if names.empty?
          puts "(no mailboxes)"
        else
          names.sort.each { |n| puts n }
        end
      rescue ArgumentError => e
        warn "error: #{e.message}"
        exit 1
      rescue Net::IMAP::NoResponseError, Net::IMAP::BadResponseError => e
        warn "imap error: #{e.message}"
        exit 2
      rescue StandardError => e
        warn "unexpected error: #{e.class}: #{e.message}"
        exit 3
      end

      desc "download", "Download new emails into a Chroma collection"
      method_option :mailbox, aliases: "-m", type: :string, default: "INBOX", desc: "Mailbox name"
      method_option :collection, type: :string, required: false, desc: "Chroma collection name (defaults to address+mailbox)"
      method_option :batch_size, type: :numeric, default: 100, desc: "Upload batch size"
      def download
        address = ENV["NITTYMAIL_IMAP_ADDRESS"]
        password = ENV["NITTYMAIL_IMAP_PASSWORD"]
        mbox = options[:mailbox] || "INBOX"
        chroma_host = ENV["NITTYMAIL_CHROMA_HOST"] || "http://chroma:8000"

        if address.to_s.empty? || password.to_s.empty?
          raise ArgumentError, "missing credentials: pass --address/--password or set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD"
        end

        safe_mbox = mbox.to_s
        # Build a default collection name and sanitize to meet Chroma rules
        default_collection = sanitize_collection_name("nittymail-#{address}-#{safe_mbox}")
        collection_name = options[:collection] || default_collection

        settings = NittyMail::Settings.new(imap_address: address, imap_password: password)
        mb = NittyMail::Mailbox.new(settings: settings, mailbox_name: mbox)

        # Preflight 1: get current uidvalidity and server uids (to_fetch since existing_uids is empty)
        puts "Preflighting mailbox '#{mbox}'..."
        plan = mb.preflight(existing_uids: [])
        uidvalidity = plan[:uidvalidity]
        server_uids = Array(plan[:to_fetch])
        puts "UIDVALIDITY=#{uidvalidity}, server_size=#{plan[:server_size]}"

        # Configure Chroma gem and get or create collection
        Chroma.connect_host = chroma_host
        # Allow overriding API base and version for compatibility (env only)
        api_base = ENV["NITTYMAIL_CHROMA_API_BASE"]
        api_version = ENV["NITTYMAIL_CHROMA_API_VERSION"]
        Chroma.api_base = api_base unless api_base.to_s.empty?
        Chroma.api_version = api_version unless api_version.to_s.empty?
        collection = Chroma::Resources::Collection.get_or_create(collection_name)

        # Discover existing docs in Chroma for this generation by paging through IDs
        prefix = "#{uidvalidity}:"
        existing_uids = []
        page = 1
        page_size = 1000
        loop do
          embeddings = collection.get(page:, page_size:)
          ids = embeddings.map(&:id)
          break if ids.empty?
          matches = ids.grep(/^#{Regexp.escape(prefix)}/).map { |id| id.split(":", 2)[1].to_i }
          existing_uids.concat(matches)
          break if ids.size < page_size
          page += 1
        end

        # Compute missing uids relative to Chroma
        to_fetch = server_uids - existing_uids
        if to_fetch.empty?
          puts "Nothing to download; collection is up to date."
          return
        end

        total_to_process = to_fetch.size
        processed = 0
        puts "Fetching #{total_to_process} message(s) from IMAP and uploading to Chroma '#{collection_name}'..."
        progress = ProgressBar.create(
          title: "Upload",
          total: total_to_process,
          progress_mark: "#",
          remainder_mark: ".",
          format: "%t %B %p%% %c/%C %e"
        )

        interrupted = false
        Signal.trap("INT") do
          if interrupted
            puts "\nForce exiting..."
            exit 130
          else
            interrupted = true
            warn "\nInterrupt received. Will stop after current batch (Ctrl-C again to force)."
          end
        end

        # Fetch messages in chunks based on Settings#max_fetch_size
        max_batch = [settings.max_fetch_size, 1000].min
        to_fetch.each_slice(max_batch) do |uid_batch|
          fetch_res = mb.fetch(uids: uid_batch)
          ids = []
          docs = []
          metas = []
          fetch_res.each do |fd|
            uid = fd.attr["UID"] || fd.attr[:UID] || fd.attr[:uid]
            raw = fd.attr["BODY[]"] || fd.attr["BODY"] || fd.attr[:BODY] || fd.attr[:"BODY[]"]
            raw = raw.to_s.dup
            raw.force_encoding("BINARY")
            safe = raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
            ids << "#{uidvalidity}:#{uid}"
            docs << safe
            metas << {address:, mailbox: mbox, uidvalidity:, uid:}
          end

          # Upload to Chroma in sub-batches for stability using chroma-db gem
          Array(ids).each_slice(options[:batch_size])
            .zip(Array(docs).each_slice(options[:batch_size]), Array(metas).each_slice(options[:batch_size]))
            .each do |id_chunk, doc_chunk, meta_chunk|
              embeddings = id_chunk.each_with_index.map do |idv, idx|
                Chroma::Resources::Embedding.new(id: idv, document: doc_chunk[idx], metadata: meta_chunk[idx])
              end
              collection.add(embeddings)
              processed += embeddings.size
              progress.progress = [processed, total_to_process].min
              break if interrupted
            end
          break if interrupted
        end
        progress.finish unless progress.finished?
        if interrupted
          puts "Download interrupted. Processed #{processed}/#{total_to_process}."
          exit 130
        else
          puts "Download complete."
        end
      rescue ArgumentError => e
        warn "error: #{e.message}"
        exit 1
      rescue Net::IMAP::NoResponseError, Net::IMAP::BadResponseError => e
        warn "imap error: #{e.message}"
        exit 2
      rescue Chroma::ChromaError => e
        details = []
        details << "status=#{e.status}" if e.respond_to?(:status)
        details << "body=#{e.body.inspect}" if e.respond_to?(:body)
        warn "chroma error: #{e.class}: #{e.message} #{details.join(' ')}"
        exit 4
      rescue StandardError => e
        warn "unexpected error: #{e.class}: #{e.message}"
        exit 3
      end

      no_commands do
        # Sanitize string into a valid Chroma collection name:
        # - 3-63 chars, start/end alphanumeric
        # - only [A-Za-z0-9_-]
        # - no consecutive periods (we remove periods entirely)
        def sanitize_collection_name(name)
          s = name.to_s.downcase
          s = s.gsub(/[^a-z0-9_-]+/, "-")  # replace invalid with '-'
          s = s.gsub(/-+/, "-")            # collapse dashes
          s = s.gsub(/^[-_]+|[-_]+$/, "")  # trim non-alnum at ends
          s = "nm" if s.length < 3
          s = s[0, 63]
          # ensure ends with alnum after truncate
          s = s.gsub(/[^a-z0-9]+\z/, "")
          s = "nm" if s.empty?
          s
        end

        # ruby-progressbar handles timing and ETA
      end
    end

    desc "mailbox SUBCOMMAND ...ARGS", "Mailbox commands"
    subcommand "mailbox", MailboxCmd
  end
end

if $PROGRAM_NAME == __FILE__
  NittyMail::CLI.start(ARGV)
end
