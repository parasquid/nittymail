# frozen_string_literal: true

require_relative "util"
require_relative "db"
require_relative "imap_client"
require "ruby-progressbar"

module NittyMail
  class MailboxRunner
    def self.run(imap_address:, imap_password:, email_ds:, mbox_name:, uidvalidity:, uids:, threads_count:, fetch_batch_size:, retry_attempts:, strict_errors:, progress: nil, embed_progress: nil, quiet: false, embedding: {enabled: false})
      # Build batches
      batch_queue = Queue.new
      uids.each_slice(fetch_batch_size) { |batch| batch_queue << batch }

      write_queue = Queue.new
      mailbox_abort = false

      insert_stmt = NittyMail::DB.prepared_insert(email_ds)

      embed_mutex = Mutex.new
      embed_counts = {enqueued: 0, embedded: 0, errors: 0}

      writer = Thread.new do
        loop do
          rec = write_queue.pop
          break if rec == :__DONE__
          begin
            to_bind = rec
            if to_bind.key?(:__embed_fields__)
              to_bind = to_bind.dup
              to_bind.delete(:__embed_fields__)
            end
            insert_stmt.call(to_bind)
          rescue Sequel::UniqueConstraintViolation => e
            raise e if strict_errors
            progress&.log("#{rec[:mailbox]} #{rec[:uid]} #{rec[:uidvalidity]} already exists, skipping ...")
          end
          # Resolve the inserted email id to attach embeddings if requested
          if embedding[:enabled]
            begin
              email_id = email_ds.where(mailbox: rec[:mailbox], uid: rec[:uid], uidvalidity: rec[:uidvalidity]).get(:id)
              if email_id
                fields = rec[:__embed_fields__] || {}
                NittyMail::Embeddings.embed_fields_for_email!(
                  email_ds.db,
                  email_id: email_id,
                  fields: fields,
                  ollama_host: embedding[:ollama_host],
                  model: embedding[:model],
                  dimension: embedding[:dimension]
                ) do |_item|
                  embed_mutex.synchronize { embed_counts[:embedded] += 1 }
                end
                if embed_progress && fields.any?
                  embed_mutex.synchronize do
                    fields.size.times { embed_progress.increment }
                  end
                end
              end
            rescue => e
              embed_mutex.synchronize { embed_counts[:errors] += 1 }
              progress&.log("embedding error for uid=#{rec[:uid]}: #{e.class}: #{e.message}")
              raise e if strict_errors
            end
          end
        end
      end

      workers = Array.new(threads_count) do
        Thread.new do
          client = NittyMail::IMAPClient.new(address: imap_address, password: imap_password)
          client.reconnect_and_select(mbox_name, uidvalidity)
          loop do
            break if mailbox_abort
            batch = begin
              batch_queue.pop(true)
            rescue ThreadError
              nil
            end
            break unless batch

            fetch_items = ["BODY.PEEK[]", "X-GM-LABELS", "X-GM-MSGID", "X-GM-THRID", "FLAGS", "UID"]
            begin
              fetched = client.fetch_with_retry(batch, fetch_items, mailbox_name: mbox_name, expected_uidvalidity: uidvalidity, retry_attempts: retry_attempts, progress: progress)
            rescue => _e
              mailbox_abort = true
              progress&.log("Aborting mailbox '#{mbox_name}' after #{retry_attempts} failed attempt(s); proceeding to next mailbox")
              break
            end
            fetched.each do |fd|
              attrs = fd.attr
              next unless attrs
              uid = attrs["UID"]
              raw = attrs["BODY[]"] || attrs["RFC822"]
              mail = NittyMail::Util.parse_mail_safely(raw, mbox_name: mbox_name, uid: uid)
              flags_json = attrs["FLAGS"].to_json
              unless quiet
                log_processing(mbox_name: mbox_name, uid: uid, mail: mail, flags_json: flags_json, raw: raw, progress: progress, strict_errors: strict_errors)
              end
              rec = build_record(
                imap_address:,
                mbox_name:,
                uid:,
                uidvalidity:,
                mail:,
                attrs:,
                flags_json:,
                raw:,
                strict_errors:
              )
              # Prepare embedding fields (subject + body text)
              if embedding[:enabled]
                begin
                  subj = rec[:subject].to_s
                  body_text = NittyMail::Util.safe_utf8(mail&.text_part&.decoded || mail&.body&.decoded)
                  # Basic HTML strip if needed
                  if body_text.include?("<") && body_text.include?(">") && mail&.text_part.nil? && mail&.html_part
                    body_text = body_text.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
                  end
                  rec[:__embed_fields__] = {}
                  rec[:__embed_fields__][:subject] = subj if subj && !subj.empty?
                  rec[:__embed_fields__][:body] = body_text if body_text && !body_text.empty?
                  embed_mutex.synchronize do
                    added = rec[:__embed_fields__].size
                    if added > 0
                      if embed_progress.nil? && !quiet
                        embed_progress = ProgressBar.create(
                          title: "embed: #{mbox_name}",
                          total: 0,
                          format: "%t: |%B| %p%% (%c/%C) [%e]"
                        )
                      end
                      embed_counts[:enqueued] += added
                      embed_progress.total = embed_progress.total + added if embed_progress
                    end
                  end
                rescue => e
                  progress&.log("embedding field prep error for uid=#{uid}: #{e.class}: #{e.message}")
                  raise e if strict_errors
                end
              end
              write_queue << rec
              # Increment progress per message processed (not per batch)
              progress&.increment
            end
          end
          client.close
        end
      end

      workers.each(&:join)
      write_queue << :__DONE__
      writer.join
      if embedding[:enabled] && embed_counts[:enqueued] > 0
        line = "embedding summary for '#{mbox_name}': enqueued=#{embed_counts[:enqueued]} embedded=#{embed_counts[:embedded]} errors=#{embed_counts[:errors]}"
        if progress
          progress.log(line)
        else
          puts line
        end
      end

      mailbox_abort ? :aborted : :ok
    end
  end
end
