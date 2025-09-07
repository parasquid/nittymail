# frozen_string_literal: true

require "thor"
require "nitty_mail"
require "active_job"
require "sidekiq"
require "redis"
require "json"
require "mail"
require "reverse_markdown"
require_relative "../../utils/utils"
require_relative "../../utils/db"
require_relative "../../models/email"
require_relative "../../utils/enricher"
require_relative "../../jobs/fetch_job"
require_relative "../../jobs/write_job"

# Suppress ActiveJob 'Enqueued ... with arguments' logs to avoid leaking credentials
begin
  require "active_support/log_subscriber"
  ActiveSupport::LogSubscriber.log_subscribers.each do |subscriber|
    if subscriber.instance_of?(ActiveJob::Logging::LogSubscriber)
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end
rescue
end

module NittyMail
  module Commands
    class MailboxDownload < Thor
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

        # Job-mode integration (default), fallback to local if Redis unreachable.
        want_jobs = !options[:no_jobs]
        if want_jobs
          begin
            adapter = ActiveJob::Base.queue_adapter
            if /TestAdapter/i.match?(adapter.class.name)
              # TestAdapter performs jobs immediately when perform_later is called,
              # so we can use job mode with it
            end
          rescue
            # If inspection fails, leave want_jobs as-is
          end
        end
        if want_jobs
          # Safety: avoid enqueuing background jobs with placeholder/example domains in non-test runs
          begin
            adapter = ActiveJob::Base.queue_adapter
            is_test_adapter = adapter && adapter.class.name =~ /TestAdapter/i
          rescue
            is_test_adapter = false
          end
          if address.to_s =~ /@example\.(com|net|org)\z/i && !is_test_adapter
            warn "jobs disabled: example.* address detected (#{address}); skipping enqueues"
            want_jobs = false
          end
        end

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
          begin
            ActiveJob::Base.queue_adapter = :sidekiq
            # Ensure Sidekiq client uses the same URL if not otherwise configured
            ENV["REDIS_URL"] ||= url
            run_id = "#{address}:#{mailbox}:#{uidvalidity}:#{Time.now.to_i}"
            redis.set("nm:dl:#{run_id}:total", total_to_process)
            redis.set("nm:dl:#{run_id}:processed", 0)
            redis.set("nm:dl:#{run_id}:errors", 0)
            redis.set("nm:dl:#{run_id}:aborted", 0)
            batch_size_jobs = options[:job_uid_batch_size].to_i
            batch_size_jobs = settings.max_fetch_size if batch_size_jobs <= 0
            # Ensure job batch size doesn't exceed server's max fetch size limit
            batch_size_jobs = [batch_size_jobs, settings.max_fetch_size].min
            aborted = false
            second_interrupt = false
            artifact_base = File.expand_path("../../job-data", __dir__)
            safe_address = address.to_s.downcase
            safe_mailbox = NittyMail::Utils.sanitize_collection_name(mailbox.to_s)
            # In test environment with TestAdapter, we'll also track DB progress to avoid hangs
            adapter = begin
              ActiveJob::Base.queue_adapter
            rescue
              nil
            end
            test_adapter = adapter && adapter.class.name =~ /TestAdapter/i
            to_fetch.to_set
            trap_handler = proc do
              if aborted
                second_interrupt = true
                puts "\nForce exit requested."
                exit 130
              else
                aborted = true
                begin
                  redis.set("nm:dl:#{run_id}:aborted", 1)
                rescue
                end
                puts "\nAborting... stopping enqueues and polling; artifacts will be retained for inspection."
              end
            end
            trap("INT", &trap_handler)

            # If using ActiveJob TestAdapter, perform enqueued jobs inline to prevent hangs
            if test_adapter
              begin
                if adapter.respond_to?(:perform_enqueued_jobs=)
                  adapter.perform_enqueued_jobs = true
                  adapter.perform_enqueued_at_jobs = true if adapter.respond_to?(:perform_enqueued_at_jobs=)
                end
              rescue
              end
            end

            to_fetch.each_slice(batch_size_jobs) do |uid_batch|
              break if aborted
              FetchJob.perform_later(
                mailbox: mailbox,
                uidvalidity: uidvalidity,
                uids: uid_batch,
                settings: ((max_fetch_override && max_fetch_override > 0) ? {max_fetch_size: max_fetch_override} : {}),
                artifact_dir: File.expand_path("../../job-data", __dir__),
                run_id: run_id,
                strict: options[:strict]
              )
            end
            progress = NittyMail::Utils.progress_bar(title: "Download(jobs)", total: total_to_process)

            poll_timeout = ENV["NITTYMAIL_POLL_TIMEOUT"].to_i
            poll_timeout = test_adapter ? 5 : 120 if poll_timeout <= 0
            started = Time.now
            interval = test_adapter ? 0.1 : 1.0
            loop do
              processed = redis.get("nm:dl:#{run_id}:processed").to_i
              errs = redis.get("nm:dl:#{run_id}:errors").to_i
              progress.progress = [processed + errs, total_to_process].min
              break if aborted || processed + errs >= total_to_process
              break if (Time.now - started) >= poll_timeout
              sleep interval
            end
            progress.finish unless progress.finished?
            if aborted
              uv_dir = File.join(artifact_base, safe_address, safe_mailbox, uidvalidity.to_s)
              puts "Aborted. processed #{redis.get("nm:dl:#{run_id}:processed")} message(s), errors #{redis.get("nm:dl:#{run_id}:errors")}."
              puts "Artifacts retained at: #{uv_dir}"
              exit 130 if second_interrupt
            else
              puts "Download complete: processed #{redis.get("nm:dl:#{run_id}:processed")} message(s), errors #{redis.get("nm:dl:#{run_id}:errors")}."
            end
            return
          rescue => e
            warn "jobs disabled: enqueue failure (#{e.class}: #{e.message}); falling back to local mode"
            # Continue into local mode below
          end
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
            message_id = nil
            header_date = nil
            from_display = nil
            reply_to_emails = nil
            in_reply_to = nil
            references_list = nil
            has_attachments = false
            to_emails = nil
            cc_emails = nil
            bcc_emails = nil
            begin
              mail = ::Mail.read_from_string(safe)
              subject = mail.subject.to_s
              message_id = mail.message_id.to_s
              begin
                header_date = mail.date&.to_time
              rescue
                header_date = nil
              end
              from_display = mail[:from]&.to_s
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
              message_id = NittyMail::Enricher.normalize_utf8(message_id)
              plain_text = NittyMail::Enricher.normalize_utf8(plain_text)
              markdown = NittyMail::Enricher.normalize_utf8(markdown)
              from_display = NittyMail::Enricher.normalize_utf8(from_display)
              has_attachments = mail.attachments && !mail.attachments.empty?
              # recipients lists (store as JSON arrays)
              to_list = Array(mail.to).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
              cc_list = Array(mail.cc).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
              bcc_list = Array(mail.bcc).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
              reply_to_list = Array(mail.reply_to).map { |a| NittyMail::Enricher.normalize_utf8(a.to_s.downcase) }
              in_reply_to = NittyMail::Enricher.normalize_utf8(mail.in_reply_to.to_s)
              references_vals = Array(mail.references).map { |x| NittyMail::Enricher.normalize_utf8(x.to_s) }
              to_emails = JSON.generate(to_list) unless to_list.empty?
              cc_emails = JSON.generate(cc_list) unless cc_list.empty?
              bcc_emails = JSON.generate(bcc_list) unless bcc_list.empty?
              reply_to_emails = JSON.generate(reply_to_list) unless reply_to_list.empty?
              references_list = JSON.generate(references_vals) unless references_vals.empty?
            rescue => e
              msg = "parse error: #{e.class}: #{e.message} uidvalidity=#{uidvalidity} uid=#{uid}"
              if strict
                raise e
              else
                warn msg + " (skipping parse; storing raw only)"
              end
            end

            # Gmail X-GM attributes
            x_gm_thrid = msg.attr["X-GM-THRID"] || msg.attr[:'X-GM-THRID'] || msg.attr[:x_gm_thrid]
            x_gm_msgid = msg.attr["X-GM-MSGID"] || msg.attr[:'X-GM-MSGID'] || msg.attr[:x_gm_msgid]

            rows << {
              address: address,
              mailbox: mailbox,
              uidvalidity: uidvalidity,
              uid: uid,
              subject: subject,
              internaldate: internal_time,
              internaldate_epoch: internal_epoch,
              date: header_date,
              rfc822_size: rfc822_size,
              from_email: from_email,
              from: from_display,
              labels_json: JSON.generate(labels),
              to_emails: to_emails,
              cc_emails: cc_emails,
              bcc_emails: bcc_emails,
              envelope_reply_to: reply_to_emails,
              envelope_in_reply_to: in_reply_to,
              envelope_references: references_list,
              message_id: message_id,
              x_gm_thrid: x_gm_thrid,
              x_gm_msgid: x_gm_msgid,
              has_attachments: has_attachments,
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
