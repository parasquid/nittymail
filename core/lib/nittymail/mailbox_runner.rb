# frozen_string_literal: true

require_relative "util"
require_relative "db"
require_relative "imap_client"
require "ruby-progressbar"

module NittyMail
  class MailboxRunner
    def self.run(settings:, email_ds:, mbox_name:, uidvalidity:, uids:, threads_count:, fetch_batch_size:, progress: nil, embedding: {enabled: false})
      # Build batches
      batch_queue = Queue.new
      uids.each_slice(fetch_batch_size) { |batch| batch_queue << batch }

      write_queue = Queue.new
      mailbox_abort = false

      insert_stmt = NittyMail::DB.prepared_insert(email_ds)

      # Embeddings are disabled in sync; no embed progress or counts here

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
            raise e if settings.strict_errors
            progress&.log("#{rec[:mailbox]} #{rec[:uid]} #{rec[:uidvalidity]} already exists, skipping ...")
          end
          # Embeddings disabled in sync: no-op after insert
        end
      end

      workers = Array.new(threads_count) do
        Thread.new do
          client = NittyMail::IMAPClient.new(address: settings.imap_address, password: settings.imap_password)
          client.reconnect_and_select(mbox_name, uidvalidity)
          loop do
            break if mailbox_abort
            batch = begin
              batch_queue.pop(true)
            rescue ThreadError
              nil
            end
            break unless batch

            fetch_items = ["BODY.PEEK[]", "X-GM-LABELS", "X-GM-MSGID", "X-GM-THRID", "FLAGS", "UID", "INTERNALDATE"]
            begin
              fetched = client.fetch_with_retry(batch, fetch_items, mailbox_name: mbox_name, expected_uidvalidity: uidvalidity, retry_attempts: settings.retry_attempts, progress: progress)
            rescue => e
              mailbox_abort = true
              progress&.log("Aborting mailbox '#{mbox_name}' after #{settings.retry_attempts} failed attempt(s) due to #{e.class}: #{e.message}; proceeding to next mailbox")
              progress&.log("Backtrace:\n" + e.backtrace.join("\n"))
              break
            end
            fetched.each do |fd|
              attrs = fd.attr
              next unless attrs
              uid = attrs["UID"]
              raw = attrs["BODY[]"] || attrs["RFC822"]
              mail = NittyMail::Util.parse_mail_safely(raw, mbox_name: mbox_name, uid: uid)
              flags_json = attrs["FLAGS"].to_json
              unless settings.quiet
                log_processing(mbox_name: mbox_name, uid: uid, mail: mail, flags_json: flags_json, raw: raw, progress: progress, strict_errors: settings.strict_errors)
              end
              rec = build_record(
                imap_address: settings.imap_address,
                mbox_name:,
                uid:,
                uidvalidity:,
                mail:,
                attrs:,
                flags_json:,
                raw:,
                strict_errors: settings.strict_errors
              )
              # Embeddings disabled in sync: do not prepare embed fields
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
      # No embedding summary in sync mode

      mailbox_abort ? :aborted : :ok
    end
  end
end
