# frozen_string_literal: true

require 'thor'
require_relative '../utils/utils'
require_relative '../utils/db'
require_relative '../workers/producer'
require_relative '../workers/consumer'
require_relative '../workers/chroma'

module NittyMail
  module Commands
    class Mailbox < Thor
      desc 'list', 'List all mailboxes for the account'
      method_option :address, aliases: '-a', type: :string, required: false, desc: 'IMAP account (email) (or env NITTYMAIL_IMAP_ADDRESS)'
      method_option :password, aliases: '-p', type: :string, required: false, desc: 'IMAP password / app password (or env NITTYMAIL_IMAP_PASSWORD)'
      def list
        address = options[:address] || ENV['NITTYMAIL_IMAP_ADDRESS']
        password = options[:password] || ENV['NITTYMAIL_IMAP_PASSWORD']

        if address.to_s.empty? || password.to_s.empty?
          raise ArgumentError, 'missing credentials: pass --address/--password or set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD'
        end

        settings = NittyMail::Settings.new(imap_address: address, imap_password: password)
        mailbox_client = NittyMail::Mailbox.new(settings: settings)
        mailboxes = Array(mailbox_client.list)

        names = mailboxes.map { |x| x.respond_to?(:name) ? x.name : x.to_s }

        if names.empty?
          puts '(no mailboxes)'
        else
          names.sort.each { |n| puts n }
        end
      rescue ArgumentError => e
        warn "error: #{e.message}"
        exit 1
      rescue Net::IMAP::NoResponseError, Net::IMAP::BadResponseError => e
        warn "imap error: #{e.message}"
        exit 2
      rescue => e
        warn "unexpected error: #{e.class}: #{e.message}"
        exit 3
      end

      desc 'download', 'Download new emails into a Chroma collection'
      method_option :mailbox, aliases: '-m', type: :string, default: 'INBOX', desc: 'Mailbox name'
      method_option :collection, type: :string, required: false, desc: 'Chroma collection name (defaults to address+mailbox)'
      method_option :upload_batch_size, type: :numeric, default: 100, desc: 'Upload batch size (env: NITTYMAIL_UPLOAD_BATCH_SIZE)'
      method_option :upload_threads, type: :numeric, default: 2, desc: 'Concurrent upload workers (env: NITTYMAIL_UPLOAD_THREADS)'
      method_option :max_fetch_size, type: :numeric, required: false, desc: 'IMAP max fetch size (env: NITTYMAIL_MAX_FETCH_SIZE, default: Settings#max_fetch_size)'
      method_option :fetch_threads, type: :numeric, default: 2, desc: 'Concurrent IMAP fetch workers (env: NITTYMAIL_FETCH_THREADS)'
      def download
        address = ENV['NITTYMAIL_IMAP_ADDRESS']
        password = ENV['NITTYMAIL_IMAP_PASSWORD']
        mailbox = options[:mailbox] || 'INBOX'

        if address.to_s.empty? || password.to_s.empty?
          raise ArgumentError, 'missing credentials: pass --address/--password or set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD'
        end

        sanitized_mailbox_name = mailbox.to_s
        default_collection = NittyMail::Utils.sanitize_collection_name("nittymail-#{address}-#{sanitized_mailbox_name}")
        collection_name = options[:collection] || default_collection

        max_fetch_override = options[:max_fetch_size]
        upload_batch_size = options[:upload_batch_size]

        settings_args = {imap_address: address, imap_password: password}
        settings_args[:max_fetch_size] = max_fetch_override if max_fetch_override && max_fetch_override > 0
        settings = NittyMail::Settings.new(**settings_args)
        mailbox_client = NittyMail::Mailbox.new(settings: settings, mailbox_name: mailbox)

        puts "Preflighting mailbox '#{mailbox}'..."
        preflight = mailbox_client.preflight(existing_uids: [])
        uidvalidity = preflight[:uidvalidity]
        server_uids = Array(preflight[:to_fetch])
        puts "UIDVALIDITY=#{uidvalidity}, server_size=#{preflight[:server_size]}"

        collection = NittyMail::DB.chroma_collection(collection_name)

        candidate_ids = server_uids.map { |u| "#{uidvalidity}:#{u}" }
        exist_threads = (ENV['NITTYMAIL_EXIST_THREADS'] || 4).to_i
        existing_ids = NittyMail::Workers::Chroma.existing_ids(
          collection: collection,
          candidate_ids: candidate_ids,
          threads: exist_threads,
          batch_size: 1000
        )
        existing_uids = existing_ids.map { |id| id.split(':', 2)[1].to_i }

        to_fetch = server_uids - existing_uids
        if to_fetch.empty?
          puts 'Nothing to download; collection is up to date.'
          return
        end

        total_to_process = to_fetch.size
        processed = 0
        puts "Fetching #{total_to_process} message(s) from IMAP and uploading to Chroma '#{collection_name}'..."
        progress = NittyMail::Utils.progress_bar(title: 'Upload', total: total_to_process)

        interrupted = false
        Signal.trap('INT') do
          if interrupted
            puts "
Force exiting..."
            exit 130
          else
            interrupted = true
            warn "
Interrupt received. Will stop after current batch (Ctrl-C again to force)."
          end
        end

        job_queue = Queue.new
        progress_mutex = Mutex.new
        errors_mutex = Mutex.new
        upload_errors = 0
        fetch_errors = 0

        upload_threads = options[:upload_threads].to_i
        upload_threads = 1 if upload_threads < 1
        upload_workers = NittyMail::Workers::Consumer.new(
          collection: collection,
          job_queue: job_queue,
          interrupted: -> { interrupted },
          on_progress: ->(count) {
            progress_mutex.synchronize do
              processed += count
              progress.progress = [processed, total_to_process].min
            end
          },
          on_error: ->(failed_count, ex, id_range) {
            errors_mutex.synchronize { upload_errors += failed_count }
            warn "upload error: #{ex.class}: #{ex.message} ids=#{id_range.first}..#{id_range.last}"
          }
        ).start(threads: upload_threads)

        fetch_queue = Queue.new
        to_fetch.each_slice(settings.max_fetch_size) { |uid_batch| fetch_queue << uid_batch }

        fetch_threads = options[:fetch_threads].to_i
        fetch_threads = 1 if fetch_threads < 1
        fetch_workers = NittyMail::Workers::Producer.new(
          settings: settings,
          mailbox_name: mailbox,
          address: address,
          uidvalidity: uidvalidity,
          upload_batch_size: upload_batch_size,
          fetch_queue: fetch_queue,
          job_queue: job_queue,
          interrupted: -> { interrupted },
          on_error: ->(type, ex, uid_batch) {
            errors_mutex.synchronize { fetch_errors += 1 }
            range = uid_batch && [uid_batch.first, uid_batch.last]
            warn "imap #{type} error: #{ex.class}: #{ex.message} batch=#{range&.first}..#{range&.last}"
          }
        ).start(threads: fetch_threads)

        status_thread = Thread.new do
          loop do
            break if interrupted
            begin
              producers_alive = fetch_workers.count(&:alive?)
              consumers_alive = upload_workers.count(&:alive?)
              progress.title = "Upload f:#{producers_alive}/#{fetch_threads} u:#{consumers_alive}/#{upload_threads} jq:#{job_queue.size} fq:#{fetch_queue.size}"
            rescue
            end
            sleep 1
          end
        end

        fetch_workers.each(&:join)
        upload_workers.size.times { job_queue << :__END__ }
        upload_workers.each(&:join)
        status_thread&.kill
        progress.finish unless progress.finished?
        if interrupted
          puts "Download interrupted. Processed #{processed}/#{total_to_process}. Upload errors: #{upload_errors}. Fetch errors: #{fetch_errors}."
          exit 130
        end
        if upload_errors > 0 || fetch_errors > 0
          warn "Download finished with errors. Failed uploads: #{upload_errors}. Fetch errors: #{fetch_errors}."
          exit 4
        end
        puts 'Download complete.'
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
      rescue => e
        warn "unexpected error: #{e.class}: #{e.message}"
        exit 3
      end
    end
  end
end
