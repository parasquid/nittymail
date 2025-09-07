# frozen_string_literal: true

require "thor"

module NittyMail
  module Commands
    class Mailbox < Thor
      namespace :mailbox

      desc "list", "List available mailboxes"
      method_option :address, aliases: "-a", type: :string, required: false, desc: "IMAP account (email) (or env NITTYMAIL_IMAP_ADDRESS)"
      method_option :password, aliases: "-p", type: :string, required: false, desc: "IMAP password / app password (or env NITTYMAIL_IMAP_PASSWORD)"
      def list
        address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
        password = options[:password] || ENV["NITTYMAIL_IMAP_PASSWORD"]

        if address.to_s.empty? || password.to_s.empty?
          puts "List all mailboxes available on the IMAP server"
          puts
          puts "USAGE:"
          puts "  cli mailbox list [options]"
          puts
          puts "OPTIONS:"
          puts "  -a, --address ADDRESS        IMAP account email (or env NITTYMAIL_IMAP_ADDRESS)"
          puts "  -p, --password PASSWORD      IMAP password (or env NITTYMAIL_IMAP_PASSWORD)"
          puts
          puts "EXAMPLES:"
          puts "  cli mailbox list"
          puts "  cli mailbox list --address user@gmail.com --password pass"
          puts
          raise ArgumentError, "Missing credentials: pass --address/--password or set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD"
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
      def download
        address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
        password = options[:password] || ENV["NITTYMAIL_IMAP_PASSWORD"]
        mailbox = options[:mailbox] || "INBOX"

        if address.to_s.empty? || password.to_s.empty?
          puts "Download emails from Gmail to local SQLite database"
          puts
          puts "USAGE:"
          puts "  cli mailbox download [options]"
          puts
          puts "OPTIONS:"
          puts "  -m, --mailbox MAILBOX        Mailbox name (default: INBOX)"
          puts "  -a, --address ADDRESS        IMAP account email (or env NITTYMAIL_IMAP_ADDRESS)"
          puts "  -p, --password PASSWORD      IMAP password (or env NITTYMAIL_IMAP_PASSWORD)"
          puts "      --database PATH          SQLite database path"
          puts "      --batch-size SIZE        DB upsert batch size (default: 200)"
          puts "      --max-fetch-size SIZE    IMAP max fetch size"
          puts "      --strict                 Fail-fast on errors instead of skipping"
          puts "      --recreate               Drop and recreate mailbox data"
          puts "  -y, --yes                    Auto-confirm destructive actions"
          puts "      --force                  Alias for --yes"
          puts "      --purge-uidvalidity ID   Delete rows for specific UIDVALIDITY"
          puts
          puts "EXAMPLES:"
          puts "  cli mailbox download --mailbox INBOX"
          puts "  cli mailbox download --address user@gmail.com --password pass --database /path/to/db.sqlite3"
          puts
          raise ArgumentError, "Missing credentials: pass --address/--password or set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD"
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

      desc "archive", "Archive emails to .eml files"
      method_option :mailbox, aliases: "-m", type: :string, default: "INBOX", desc: "Mailbox name"
      method_option :output, type: :string, required: false, desc: "Archive output base directory (default: cli/archives)"
      method_option :max_fetch_size, type: :numeric, required: false, desc: "IMAP max fetch size (env: NITTYMAIL_MAX_FETCH_SIZE, default: Settings#max_fetch_size)"
      method_option :address, aliases: "-a", type: :string, required: false, desc: "IMAP account (email) (or env NITTYMAIL_IMAP_ADDRESS)"
      method_option :password, aliases: "-p", type: :string, required: false, desc: "IMAP password / app password (or env NITTYMAIL_IMAP_PASSWORD)"
      method_option :strict, type: :boolean, default: false, desc: "Fail-fast on errors instead of skipping"
      def archive
        address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
        password = options[:password] || ENV["NITTYMAIL_IMAP_PASSWORD"]
        mailbox = options[:mailbox] || "INBOX"

        # Show usage if credentials are missing
        if address.to_s.empty? || password.to_s.empty?
          puts "Archive emails from Gmail to local .eml files"
          puts
          puts "USAGE:"
          puts "  cli mailbox archive [options]"
          puts
          puts "OPTIONS:"
          puts "  -m, --mailbox MAILBOX        Mailbox name (default: INBOX)"
          puts "  -a, --address ADDRESS        IMAP account email (or env NITTYMAIL_IMAP_ADDRESS)"
          puts "  -p, --password PASSWORD      IMAP password (or env NITTYMAIL_IMAP_PASSWORD)"
          puts "      --output PATH            Archive output directory (default: cli/archives)"
          puts "      --max-fetch-size SIZE    IMAP max fetch size (env: NITTYMAIL_MAX_FETCH_SIZE)"
          puts "      --strict                 Fail-fast on errors instead of skipping"
          puts
          puts "EXAMPLES:"
          puts "  cli mailbox archive --mailbox INBOX"
          puts "  cli mailbox archive --address user@gmail.com --password pass --output /path/to/archive"
          puts
          raise ArgumentError, "Missing credentials: pass --address/--password or set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD"
        end

        # Resolve output base and ensure .keep exists
        out_base = options[:output]
        out_base ||= File.expand_path("../../archives", __dir__)
        FileUtils.mkdir_p(out_base)
        keep = File.join(out_base, ".keep")
        File.write(keep, "Keep this directory in git; archive files are ignored.\n") unless File.exist?(keep)

        strict = !!options[:strict]
        max_fetch_override = options[:max_fetch_size]
        settings_args = {imap_address: address, imap_password: password}
        settings_args[:max_fetch_size] = max_fetch_override if max_fetch_override && max_fetch_override > 0
        settings = NittyMail::Settings.new(**settings_args)
        mailbox_client = NittyMail::Mailbox.new(settings: settings, mailbox_name: mailbox)

        puts "Preflighting mailbox '#{mailbox}' for archive..."
        preflight = mailbox_client.preflight(existing_uids: [])
        uidvalidity = preflight[:uidvalidity]
        server_uids = Array(preflight[:to_fetch])
        puts "UIDVALIDITY=#{uidvalidity}, server_size=#{preflight[:server_size]}"

        # Determine which UIDs need archiving by checking for existing files
        safe_address = address.to_s.downcase
        safe_mailbox = NittyMail::Utils.sanitize_collection_name(mailbox.to_s)
        uv_dir = File.join(out_base, safe_address, safe_mailbox, uidvalidity.to_s)
        FileUtils.mkdir_p(uv_dir)
        existing = Dir.exist?(uv_dir) ? Dir.children(uv_dir).grep(/\.eml\z/).map { |f| f.sub(/\.eml\z/, "").to_i }.to_set : Set.new
        to_archive = server_uids.reject { |u| existing.include?(u) }
        total_to_process = to_archive.size
        if total_to_process <= 0
          puts "Nothing to archive. Folder is up to date."
          return
        end

        # Local single-process archiving
        progress = NittyMail::Utils.progress_bar(title: "Archive", total: total_to_process)
        processed = 0
        to_archive.each_slice(settings.max_fetch_size) do |uid_batch|
          begin
            fetch_response = mailbox_client.fetch(uids: uid_batch)
          rescue => e
            if strict
              raise e
            else
              warn "imap fetch error: #{e.class}: #{e.message} batch=#{uid_batch.first}..#{uid_batch.last} (skipping)"
              next
            end
          end
          fetch_response.each do |msg|
            uid = msg.attr["UID"] || msg.attr[:UID] || msg.attr[:uid]
            raw = msg.attr["BODY[]"] || msg.attr["BODY"] || msg.attr[:BODY] || msg.attr[:'BODY[]']
            raw = raw.to_s.dup
            raw.force_encoding("BINARY")

            # Extract Gmail-specific headers from IMAP response
            x_gm_thrid = msg.attr["X-GM-THRID"] || msg.attr[:'X-GM-THRID'] || msg.attr[:x_gm_thrid]
            x_gm_msgid = msg.attr["X-GM-MSGID"] || msg.attr[:'X-GM-MSGID'] || msg.attr[:x_gm_msgid]
            x_gm_labels = msg.attr["X-GM-LABELS"] || msg.attr[:'X-GM-LABELS'] || msg.attr[:x_gm_labels]

            # Check if Gmail headers are missing from raw message and add them
            raw_str = raw.dup.force_encoding("UTF-8")
            headers_to_add = []

            unless raw_str.include?("X-GM-THRID:") || x_gm_thrid.nil?
              headers_to_add << "X-GM-THRID: #{x_gm_thrid}"
            end

            unless raw_str.include?("X-GM-MSGID:") || x_gm_msgid.nil?
              headers_to_add << "X-GM-MSGID: #{x_gm_msgid}"
            end

            unless raw_str.include?("X-GM-LABELS:") || x_gm_labels.nil? || x_gm_labels.empty?
              labels_str = Array(x_gm_labels).map(&:to_s).join(" ")
              headers_to_add << "X-GM-LABELS: #{labels_str}" unless labels_str.empty?
            end

            # If we have headers to add, insert them after the main headers
            unless headers_to_add.empty?
              # Find the end of headers (double newline)
              header_end_idx = raw_str.index("\r\n\r\n") || raw_str.index("\n\n")
              raw = if header_end_idx
                # Insert headers before the body
                raw_str[0...header_end_idx] +
                  "\r\n" + headers_to_add.join("\r\n") +
                  raw_str[header_end_idx..]
              else
                # Fallback: append headers at the end
                raw_str + "\r\n" + headers_to_add.join("\r\n") + "\r\n\r\n"
              end
              raw = raw.force_encoding("BINARY")
            end

            final = File.join(uv_dir, "#{uid}.eml")
            next if File.exist?(final)
            tmp = File.join(uv_dir, ".#{uid}.eml.tmp")
            File.binwrite(tmp, raw)
            File.rename(tmp, final)
            processed += 1
            progress.progress = [processed, total_to_process].min
          rescue => e
            if strict
              raise e
            else
              warn "archive write error: #{e.class}: #{e.message} uid=#{uid} (skipping)"
            end
          ensure
            begin
              File.delete(tmp) if tmp && File.exist?(tmp)
            rescue
            end
          end
        ensure
          begin
            File.delete(tmp) if tmp && File.exist?(tmp)
          rescue
          end
        end
        progress.finish unless progress.finished?
        puts "Archive complete: processed #{processed} file(s)."
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
