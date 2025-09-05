# frozen_string_literal: true

require "thor"
require "nitty_mail"
require "active_job"
require "sidekiq"
require "redis"
require "json"
require "mail"
require "reverse_markdown"
require_relative "../utils/utils"
require_relative "../utils/db"
require_relative "../models/email"
require_relative "../utils/enricher"

module NittyMail
  module Commands
    class Mailbox < Thor
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
        begin
          if mailbox_client.respond_to?(:close)
            mailbox_client.close
          elsif mailbox_client.respond_to?(:disconnect)
            mailbox_client.disconnect
          elsif mailbox_client.respond_to?(:logout)
            mailbox_client.logout
          end
        rescue
        end

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
      rescue => e
        warn "unexpected error: #{e.class}: #{e.message}"
        exit 3
      end

      desc "download", "Download new emails into a local SQLite database"
      method_option :mailbox, aliases: "-m", type: :string, default: "INBOX", desc: "Mailbox name"
      method_option :database, type: :string, required: false, desc: "SQLite database path (default: NITTYMAIL_SQLITE_DB or cli/nittymail.sqlite3)"
      method_option :batch_size, type: :numeric, default: 200, desc: "DB upsert batch size"
      method_option :max_fetch_size, type: :numeric, required: false, desc: "IMAP max fetch size (env: NITTYMAIL_MAX_FETCH_SIZE, default: Settings#max_fetch_size)"
      method_option :address, aliases: "-a", type: :string, required: false, desc: "IMAP account (email) (or env NITTYMAIL_IMAP_ADDRESS)"
      method_option :password, aliases: "-p", type: :string, required: false, desc: "IMAP password / app password (or env NITTYMAIL_IMAP_PASSWORD)"
      method_option :strict, type: :boolean, default: false, desc: "Fail-fast on errors instead of skipping"
      method_option :recreate, type: :boolean, default: false, desc: "Drop and recreate rows for this mailbox+uidvalidity"
      method_option :yes, type: :boolean, default: false, desc: "Auto-confirm destructive actions"
      method_option :force, type: :boolean, default: false, desc: "Alias for --yes"
      method_option :purge_uidvalidity, type: :numeric, required: false, desc: "Delete rows for a specific UIDVALIDITY and exit"
      method_option :no_jobs, type: :boolean, default: false, desc: "Force single-process mode (default is job mode)"
      method_option :job_uid_batch_size, type: :numeric, default: 200, desc: "UID batch size per fetch job"
      def download
        address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
        password = options[:password] || ENV["NITTYMAIL_IMAP_PASSWORD"]
        mailbox = options[:mailbox] || "INBOX"

        if address.to_s.empty? || password.to_s.empty?
          raise ArgumentError, "missing credentials: pass --address/--password or set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD"
        end

        # DB setup
        db_path = options[:database]
        NittyMail::DB.establish_sqlite_connection(database_path: db_path, address: address)
        NittyMail::DB.run_migrations!

        strict = !!options[:strict]
        max_fetch_override = options[:max_fetch_size]
        batch_size = options[:batch_size].to_i
        batch_size = 200 if batch_size <= 0

        settings_args = {imap_address: address, imap_password: password}
        settings_args[:max_fetch_size] = max_fetch_override if max_fetch_override && max_fetch_override > 0
        settings = NittyMail::Settings.new(**settings_args)
        mailbox_client = NittyMail::Mailbox.new(settings: settings, mailbox_name: mailbox)

        puts "Preflighting mailbox '#{mailbox}'..."
        preflight = mailbox_client.preflight(existing_uids: [])
        uidvalidity = preflight[:uidvalidity]
        server_uids = Array(preflight[:to_fetch])
        puts "UIDVALIDITY=#{uidvalidity}, server_size=#{preflight[:server_size]}"

        # Handle purge-only mode
        purge_val = options[:purge_uidvalidity]
        if purge_val
          confirm = options[:yes] || options[:force]
          unless confirm
            answer = ask("This will DELETE rows for #{address} #{mailbox} UIDVALIDITY=#{purge_val}. Type 'DELETE' to confirm:")
            confirm = (answer == "DELETE")
          end
          unless confirm
            warn "Purge cancelled."
            return
          end
          deleted = NittyMail::Email.where(address: address, mailbox: mailbox, uidvalidity: purge_val).delete_all
          puts "Purged #{deleted} row(s) for UIDVALIDITY=#{purge_val}."
          return
        end

        # Recreate mode: delete current generation before fetching
        if options[:recreate]
          confirm = options[:yes] || options[:force]
          unless confirm
            answer = ask("This will DELETE rows for #{address} #{mailbox} UIDVALIDITY=#{uidvalidity}. Type 'DELETE' to confirm:")
            confirm = (answer == "DELETE")
          end
          unless confirm
            warn "Recreate cancelled."
            return
          end
          dropped = NittyMail::Email.where(address: address, mailbox: mailbox, uidvalidity: uidvalidity).delete_all
          puts "Dropped #{dropped} row(s) for UIDVALIDITY=#{uidvalidity} (recreate)."
        end

        existing_uids = NittyMail::Email.where(address: address, mailbox: mailbox, uidvalidity: uidvalidity).pluck(:uid).to_set
        to_fetch = server_uids.reject { |u| existing_uids.include?(u) }
        total_to_process = to_fetch.size
        if total_to_process <= 0
          puts "Nothing to download. Database is up to date."
          return
        end

        # Job-mode integration (default), fallback to local if Redis unreachable
        want_jobs = !options[:no_jobs]
        if want_jobs
          url = ENV["REDIS_URL"] || "redis://redis:6379/0"
          begin
            redis = ::Redis.new(url: url, timeout: 1.0)
            redis.ping
          rescue => e
            warn "jobs disabled: redis not reachable (#{e.class}: #{e.message}); falling back to local mode"
            redis = nil
          end
        end

        if want_jobs && redis
          ActiveJob::Base.queue_adapter = :sidekiq
          require_relative "../jobs/fetch_job"
          require_relative "../jobs/write_job"
          run_id = "#{address}:#{mailbox}:#{uidvalidity}:#{Time.now.to_i}"
          redis.set("nm:dl:#{run_id}:total", total_to_process)
          redis.set("nm:dl:#{run_id}:processed", 0)
          redis.set("nm:dl:#{run_id}:errors", 0)
          redis.set("nm:dl:#{run_id}:aborted", 0)
          batch_size_jobs = options[:job_uid_batch_size].to_i
          batch_size_jobs = settings.max_fetch_size if batch_size_jobs <= 0
          aborted = false
          second_interrupt = false
          artifact_base = File.expand_path("../job-data", __dir__)
          safe_address = address.to_s.downcase
          safe_mailbox = NittyMail::Utils.sanitize_collection_name(mailbox.to_s)
          trap_handler = proc do
            if aborted
              second_interrupt = true
              puts "\nForce exit requested."
            else
              aborted = true
              begin
                redis.set("nm:dl:#{run_id}:aborted", 1)
              rescue
              end
              puts "\nAborting... stopping enqueues and polling; cleaning up artifacts."
            end
          end
          trap("INT", &trap_handler)

          to_fetch.each_slice(batch_size_jobs) do |uid_batch|
            break if aborted
            FetchJob.perform_later(
              address: address,
              password: password,
              mailbox: mailbox,
              uidvalidity: uidvalidity,
              uids: uid_batch,
              settings: ((max_fetch_override && max_fetch_override > 0) ? {max_fetch_size: max_fetch_override} : {}),
              artifact_dir: File.expand_path("../job-data", __dir__),
              run_id: run_id,
              strict: options[:strict]
            )
          end
          progress = NittyMail::Utils.progress_bar(title: "Download(jobs)", total: total_to_process)
          loop do
            processed = redis.get("nm:dl:#{run_id}:processed").to_i
            errs = redis.get("nm:dl:#{run_id}:errors").to_i
            progress.progress = [processed + errs, total_to_process].min
            break if aborted || processed + errs >= total_to_process
            sleep 1
          end
          progress.finish unless progress.finished?
          if aborted
            # Best-effort cleanup: delete remaining artifact files
            uv_dir = File.join(artifact_base, safe_address, safe_mailbox, uidvalidity.to_s)
            begin
              # target expected UID files
              to_fetch.each do |uid|
                path = File.join(uv_dir, "#{uid}.eml")
                File.delete(path) if File.exist?(path)
              end
              # and sweep any stray .eml files for this run scope
              Dir.glob(File.join(uv_dir, "*.eml")).each do |path|
                File.delete(path)
              rescue
                nil
              end
              # remove empty directories for tidiness
              begin
                Dir.rmdir(uv_dir)
              rescue
              end
            rescue
            end
            puts "Aborted. processed #{redis.get("nm:dl:#{run_id}:processed")} message(s), errors #{redis.get("nm:dl:#{run_id}:errors")}."
            exit 130 if second_interrupt
          else
            puts "Download complete: processed #{redis.get("nm:dl:#{run_id}:processed")} message(s), errors #{redis.get("nm:dl:#{run_id}:errors")}."
          end
          return
        end

        progress = NittyMail::Utils.progress_bar(title: "Download", total: total_to_process)
        processed = 0

        to_fetch.each_slice(settings.max_fetch_size) do |uid_batch|
          fetch_response = begin
            mailbox_client.fetch(uids: uid_batch)
          rescue => e
            msg = "imap fetch error: #{e.class}: #{e.message} batch=#{uid_batch.first}..#{uid_batch.last}"
            if strict
              raise e
            else
              warn msg + " (skipping)"
              next
            end
          end
          rows = []
          fetch_response.each do |msg|
            uid = msg.attr["UID"] || msg.attr[:UID] || msg.attr[:uid]
            raw = msg.attr["BODY[]"] || msg.attr["BODY"] || msg.attr[:BODY] || msg.attr[:'BODY[]']
            raw = raw.to_s.dup
            raw.force_encoding("BINARY")
            safe = begin
              raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
            rescue => e
              if strict
                raise e
              else
                raw.to_s
              end
            end
            internal = msg.attr["INTERNALDATE"] || msg.attr[:INTERNALDATE] || msg.attr[:internaldate]
            internal_time = internal.is_a?(Time) ? internal : (begin
              require "time"
              Time.parse(internal.to_s)
            rescue
              Time.at(0)
            end)
            internal_epoch = internal_time.to_i

            envelope = msg.attr["ENVELOPE"] || msg.attr[:ENVELOPE] || msg.attr[:envelope]
            from_email = begin
              addrs = envelope&.from
              addr = Array(addrs).first
              m = addr&.mailbox&.to_s
              h = addr&.host&.to_s
              fe = (m && h && !m.empty? && !h.empty?) ? "#{m}@#{h}".downcase : nil
              fe ? NittyMail::Enricher.normalize_utf8(fe) : nil
            rescue
              nil
            end

            labels_attr = msg.attr["X-GM-LABELS"] || msg.attr[:'X-GM-LABELS'] || msg.attr[:x_gm_labels]
            labels = Array(labels_attr).map { |v| NittyMail::Enricher.normalize_utf8(v.to_s) }

            size_attr = msg.attr["RFC822.SIZE"] || msg.attr[:'RFC822.SIZE']
            rfc822_size = size_attr.to_i

            subject = ""
            plain_text = ""
            markdown = ""
            to_emails = nil
            cc_emails = nil
            bcc_emails = nil
            begin
              mail = ::Mail.read_from_string(safe)
              subject = mail.subject.to_s
              text_part = NittyMail::Enricher.safe_decode(mail.text_part)
              html_part = NittyMail::Enricher.safe_decode(mail.html_part)
              body_fallback = NittyMail::Enricher.safe_decode(mail.body)
              plain_text = text_part.to_s.strip.empty? ? body_fallback.to_s : text_part.to_s
              markdown = if html_part && !html_part.to_s.strip.empty?
                ::ReverseMarkdown.convert(html_part.to_s)
              else
                ::ReverseMarkdown.convert(plain_text.to_s)
              end
              # normalize encodings to UTF-8 for DB writes
              subject = NittyMail::Enricher.normalize_utf8(subject)
              plain_text = NittyMail::Enricher.normalize_utf8(plain_text)
              markdown = NittyMail::Enricher.normalize_utf8(markdown)
              # recipients lists (store as JSON arrays)
              to_list = Array(mail.to).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
              cc_list = Array(mail.cc).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
              bcc_list = Array(mail.bcc).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
              to_emails = JSON.generate(to_list) unless to_list.empty?
              cc_emails = JSON.generate(cc_list) unless cc_list.empty?
              bcc_emails = JSON.generate(bcc_list) unless bcc_list.empty?
            rescue => e
              msg = "parse error: #{e.class}: #{e.message} uidvalidity=#{uidvalidity} uid=#{uid}"
              if strict
                raise e
              else
                warn msg + " (skipping parse; storing raw only)"
              end
            end

            rows << {
              address: address,
              mailbox: mailbox,
              uidvalidity: uidvalidity,
              uid: uid,
              subject: subject,
              internaldate: internal_time,
              internaldate_epoch: internal_epoch,
              rfc822_size: rfc822_size,
              from_email: from_email,
              labels_json: JSON.generate(labels),
              to_emails: to_emails,
              cc_emails: cc_emails,
              bcc_emails: bcc_emails,
              raw: raw,
              plain_text: plain_text,
              markdown: markdown,
              created_at: Time.now,
              updated_at: Time.now
            }
          rescue Encoding::CompatibilityError, ArgumentError => e
            msg = "processing error: #{e.class}: #{e.message} uidvalidity=#{uidvalidity} uid=#{uid}"
            if strict
              raise e
            else
              warn msg + " (skipping message)"
              next
            end
          rescue => e
            msg = "unexpected processing error: #{e.class}: #{e.message} uidvalidity=#{uidvalidity} uid=#{uid}"
            if strict
              raise e
            else
              warn msg + " (skipping message)"
              next
            end
          end

          rows.each_slice(batch_size) do |chunk|
            NittyMail::Email.upsert_all(chunk, unique_by: "index_emails_on_identity")
            processed += chunk.size
            progress.progress = [processed, total_to_process].min
          rescue => e
            if strict
              raise e
            else
              warn "db upsert error: #{e.class}: #{e.message} (retrying per-row for chunk of #{chunk.size})"
              chunk.each do |row|
                NittyMail::Email.upsert_all([row], unique_by: "index_emails_on_identity")
                processed += 1
                progress.progress = [processed, total_to_process].min
              rescue => e2
                warn "db upsert row error: #{e2.class}: #{e2.message} uidvalidity=#{row[:uidvalidity]} uid=#{row[:uid]} (skipping row)"
              end
            end
          end
        end

        progress.finish unless progress.finished?
        puts "Download complete: processed #{processed} message(s)."
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
    end
  end
end
