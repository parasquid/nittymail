# frozen_string_literal: true

require "thor"
require "nitty_mail"
require "fileutils"
require_relative "../../utils/utils"

module NittyMail
  module Commands
    class MailboxArchive < Thor
      desc "archive", "Archive all emails as raw .eml files by UID"
      method_option :mailbox, aliases: "-m", type: :string, default: "INBOX", desc: "Mailbox name"
      method_option :output, type: :string, required: false, desc: "Archive output base directory (default: cli/archives)"
      method_option :max_fetch_size, type: :numeric, required: false, desc: "IMAP max fetch size (env: NITTYMAIL_MAX_FETCH_SIZE, default: Settings#max_fetch_size)"
      method_option :address, aliases: "-a", type: :string, required: false, desc: "IMAP account (email) (or env NITTYMAIL_IMAP_ADDRESS)"
      method_option :password, aliases: "-p", type: :string, required: false, desc: "IMAP password / app password (or env NITTYMAIL_IMAP_PASSWORD)"
      method_option :strict, type: :boolean, default: false, desc: "Fail-fast on errors instead of skipping"
      def archive
        begin
          address = options[:address] || ENV["NITTYMAIL_IMAP_ADDRESS"]
          password = options[:password] || ENV["NITTYMAIL_IMAP_PASSWORD"]
          mailbox = options[:mailbox] || "INBOX"
          raise ArgumentError, "missing credentials: pass --address/--password or set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD" if address.to_s.empty? || password.to_s.empty?

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
              raw = msg.attr["BODY[]"] || msg.attr["BODY"] || msg.attr[:BODY] || msg.attr[:"BODY[]"]
              raw = raw.to_s.dup
              raw.force_encoding("BINARY")
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
            raw = msg.attr["BODY[]"] || msg.attr["BODY"] || msg.attr[:BODY] || msg.attr[:"BODY[]"]
            raw = raw.to_s.dup
            raw.force_encoding("BINARY")
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
