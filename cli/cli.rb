#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "thor"
require "json"
require "uri"
require "net/http"
require "thread"
require "nitty_mail"
require "chroma-db"
require "ruby-progressbar"
require_relative "utils/utils"
require_relative "utils/db"

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
        mailbox_client = NittyMail::Mailbox.new(settings: settings)
        mailboxes = Array(mailbox_client.list)

        names = mailboxes.map { |x| x.respond_to?(:name) ? x.name : x.to_s }

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
      method_option :upload_batch_size, type: :numeric, default: 100, desc: "Upload batch size (env: NITTYMAIL_UPLOAD_BATCH_SIZE)"
      method_option :upload_threads, type: :numeric, default: 2, desc: "Concurrent upload workers (env: NITTYMAIL_UPLOAD_THREADS)"
      method_option :max_fetch_size, type: :numeric, required: false, desc: "IMAP max fetch size (env: NITTYMAIL_MAX_FETCH_SIZE, default: Settings#max_fetch_size)"
      method_option :fetch_threads, type: :numeric, default: 2, desc: "Concurrent IMAP fetch workers (env: NITTYMAIL_FETCH_THREADS)"
      def download
        address = ENV["NITTYMAIL_IMAP_ADDRESS"]
        password = ENV["NITTYMAIL_IMAP_PASSWORD"]
        mailbox = options[:mailbox] || "INBOX"

        if address.to_s.empty? || password.to_s.empty?
          raise ArgumentError, "missing credentials: pass --address/--password or set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD"
        end

        sanitized_mailbox_name = mailbox.to_s
        # Build a default collection name and sanitize to meet Chroma rules
        default_collection = NittyMail::Utils.sanitize_collection_name("nittymail-#{address}-#{sanitized_mailbox_name}")
        collection_name = options[:collection] || default_collection

        # Tunables from flags
        max_fetch_override = options[:max_fetch_size]
        upload_batch_size = options[:upload_batch_size]

        # Initialize settings, honoring fetch override via Settings#max_fetch_size
        settings_args = {imap_address: address, imap_password: password}
        settings_args[:max_fetch_size] = max_fetch_override if max_fetch_override && max_fetch_override > 0
        settings = NittyMail::Settings.new(**settings_args)
        mailbox_client = NittyMail::Mailbox.new(settings: settings, mailbox_name: mailbox)

        # Preflight 1: get current uidvalidity and server uids (to_fetch since existing_uids is empty)
        puts "Preflighting mailbox '#{mailbox}'..."
        preflight = mailbox_client.preflight(existing_uids: [])
        uidvalidity = preflight[:uidvalidity]
        server_uids = Array(preflight[:to_fetch])
        puts "UIDVALIDITY=#{uidvalidity}, server_size=#{preflight[:server_size]}"

        # Configure Chroma via NittyMail::DB helper and get or create collection
        collection = NittyMail::DB.chroma_collection(collection_name)

        # Discover existing docs in Chroma for this generation by paging through IDs
        id_prefix = "#{uidvalidity}:"
        existing_uids = []
        page = 1
        page_size = 1000
        begin
          # Prefer server-side filtering by uidvalidity when available
          loop do
            embeddings = collection.get(page:, page_size:, where: {uidvalidity: uidvalidity})
            ids = embeddings.map(&:id)
            break if ids.empty?
            matches = ids.map { |id| id.split(":", 2)[1].to_i }
            existing_uids.concat(matches)
            break if ids.size < page_size
            page += 1
          end
        rescue Chroma::APIError, NoMethodError
          # Fallback: client-side filter by ID prefix
          page = 1
          loop do
            embeddings = collection.get(page:, page_size:)
            ids = embeddings.map(&:id)
            break if ids.empty?
            matches = ids.grep(/^#{Regexp.escape(id_prefix)}/).map { |id| id.split(":", 2)[1].to_i }
            existing_uids.concat(matches)
            break if ids.size < page_size
            page += 1
          end
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
          format: "%t: |%B| %p%% (%c/%C) [%e]"
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

        # Producer-consumer pipeline
        job_queue = Queue.new
        progress_mutex = Mutex.new
        errors_mutex = Mutex.new
        upload_errors = 0
        fetch_errors = 0

        # Consumers: upload workers
        upload_threads = options[:upload_threads].to_i
        upload_threads = 1 if upload_threads < 1
        upload_workers = Array.new(upload_threads) do
          Thread.new do
            until interrupted
              upload_job = job_queue.pop
              break if upload_job.equal?(:__END__)

              id_batch, doc_batch, meta_batch = upload_job
              begin
                embeddings = id_batch.each_with_index.map do |idv, idx|
                  Chroma::Resources::Embedding.new(id: idv, document: doc_batch[idx], metadata: meta_batch[idx])
                end
                collection.add(embeddings)
                progress_mutex.synchronize do
                  processed += embeddings.size
                  progress.progress = [processed, total_to_process].min
                end
              rescue Chroma::ChromaError => e
                errors_mutex.synchronize { upload_errors += id_batch.size }
                warn "chroma upload error: #{e.class}: #{e.message} ids=#{id_batch.first}..#{id_batch.last}"
              rescue => e
                errors_mutex.synchronize { upload_errors += id_batch.size }
                warn "unexpected upload error: #{e.class}: #{e.message} ids=#{id_batch.first}..#{id_batch.last}"
              end

            end
          end
        end

        # Build fetch queue of UID batches
        fetch_queue = Queue.new
        to_fetch.each_slice(settings.max_fetch_size) { |uid_batch| fetch_queue << uid_batch }

        # Producer workers: parallel IMAP fetchers
        fetch_threads = options[:fetch_threads].to_i
        fetch_threads = 1 if fetch_threads < 1
        fetch_workers = Array.new(fetch_threads) do
          Thread.new do
            # One IMAP connection per fetch worker
            thread_mailbox_client = NittyMail::Mailbox.new(settings: settings, mailbox_name: mailbox)
            until interrupted
              uid_batch = begin
                fetch_queue.pop(true)
              rescue ThreadError
                break
              end

              begin
                fetch_response = thread_mailbox_client.fetch(uids: uid_batch)
                doc_ids = []
                documents = []
                metadata_list = []
                fetch_response.each do |msg|
                  uid = msg.attr["UID"] || msg.attr[:UID] || msg.attr[:uid]
                  raw = msg.attr["BODY[]"] || msg.attr["BODY"] || msg.attr[:BODY] || msg.attr[:"BODY[]"]
                  raw = raw.to_s.dup
                  raw.force_encoding("BINARY")
                  safe = raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
                  doc_ids << "#{uidvalidity}:#{uid}"
                  documents << safe
                  metadata_list << {address:, mailbox:, uidvalidity:, uid:}
                end

                Array(doc_ids).each_slice(upload_batch_size)
                  .zip(Array(documents).each_slice(upload_batch_size), Array(metadata_list).each_slice(upload_batch_size))
                  .each do |id_batch, doc_batch, meta_batch|
                    job_queue << [id_batch, doc_batch, meta_batch]
                  end
              rescue Net::IMAP::NoResponseError, Net::IMAP::BadResponseError => e
                errors_mutex.synchronize { fetch_errors += 1 }
                warn "imap fetch error: #{e.message} batch=#{uid_batch.first}..#{uid_batch.last}"
              rescue => e
                errors_mutex.synchronize { fetch_errors += 1 }
                warn "unexpected fetch error: #{e.class}: #{e.message} batch=#{uid_batch.first}..#{uid_batch.last}"
              end
            end
          end
        end

        # Wait for fetchers to finish, then signal consumers to stop
        fetch_workers.each(&:join)
        upload_workers.size.times { job_queue << :__END__ }
        upload_workers.each(&:join)
        progress.finish unless progress.finished?
        if interrupted
          puts "Download interrupted. Processed #{processed}/#{total_to_process}. Upload errors: #{upload_errors}. Fetch errors: #{fetch_errors}."
          exit 130
        end
        if upload_errors > 0 || fetch_errors > 0
          warn "Download finished with errors. Failed uploads: #{upload_errors}. Fetch errors: #{fetch_errors}."
          exit 4
        end
        puts "Download complete."
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

      # ruby-progressbar handles timing and ETA
    end

    desc "mailbox SUBCOMMAND ...ARGS", "Mailbox commands"
    subcommand "mailbox", MailboxCmd
  end
end

if $PROGRAM_NAME == __FILE__
  NittyMail::CLI.start(ARGV)
end
