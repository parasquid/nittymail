# frozen_string_literal: true

# Copyright 2025 parasquid

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

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
      processed_count = 0
      error_count = 0

      insert_stmt = NittyMail::DB.prepared_insert(email_ds)

      # Embeddings are disabled in sync; no embed progress or counts here

      writer = Thread.new do
        progress&.event(:sync_writer_started, {mailbox: mbox_name, thread: Thread.current.object_id})
        while (rec = write_queue.pop)
          break if rec == :__DONE__
          begin
            to_bind = rec
            if to_bind.key?(:__embed_fields__)
              to_bind = to_bind.dup
              to_bind.delete(:__embed_fields__)
            end
            insert_stmt.call(to_bind)
            # Advance progress only from the single writer thread to avoid
            # concurrency issues in progressbar rendering.
            progress&.event(:sync_message_processed, {mailbox: mbox_name, uid: rec[:uid]})
          rescue Sequel::UniqueConstraintViolation => e
            raise e if settings.strict_errors
            progress&.event(:sync_log, {message: "#{rec[:mailbox]} #{rec[:uid]} #{rec[:uidvalidity]} already exists, skipping ..."})
          rescue => e
            # Handle other database errors
            if settings.strict_errors
              raise e
            else
              progress&.event(:sync_log, {message: "Database error for #{rec[:mailbox]} #{rec[:uid]}: #{e.class}: #{e.message}"})
              error_count += 1
            end
          end
          # Embeddings disabled in sync: no-op after insert
        end
        progress&.event(:sync_writer_stopped, {mailbox: mbox_name, thread: Thread.current.object_id})
      rescue => e
        # Catch any unhandled exceptions in writer thread to prevent silent exits
        progress&.event(:sync_log, {message: "FATAL: Writer thread crashed: #{e.class}: #{e.message}"})
        progress&.event(:sync_log, {message: "Backtrace:\n" + e.backtrace.join("\n")})
        # Re-raise to ensure the exception is visible if Thread.abort_on_exception is true
        error_count += 1
        raise e
      end

      workers = Array.new(threads_count) do
        Thread.new do
          progress&.event(:sync_worker_started, {mailbox: mbox_name, thread: Thread.current.object_id})
          client = NittyMail::IMAPClient.new(address: settings.imap_address, password: settings.imap_password)
          client.reconnect_and_select(mbox_name, uidvalidity)
          while !mailbox_abort && (batch = begin
            batch_queue.pop(true)
          rescue
            nil
          end)

            fetch_items = ["BODY.PEEK[]", "X-GM-LABELS", "X-GM-MSGID", "X-GM-THRID", "FLAGS", "UID", "INTERNALDATE"]
            begin
              progress&.event(:sync_fetch_started, {mailbox: mbox_name, batch_size: batch.size})
              fetched = client.fetch_with_retry(batch, fetch_items, mailbox_name: mbox_name, expected_uidvalidity: uidvalidity, retry_attempts: settings.retry_attempts, progress: progress)
              progress&.event(:sync_fetch_finished, {mailbox: mbox_name, count: fetched.size})
            rescue => e
              mailbox_abort = true
              progress&.event(:sync_log, {message: "Aborting mailbox '#{mbox_name}' after #{settings.retry_attempts} failed attempt(s) due to #{e.class}: #{e.message}; proceeding to next mailbox"})
              progress&.event(:sync_log, {message: "Backtrace:\n" + e.backtrace.join("\n")})
              error_count += 1
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
                # emit the log line as an event instead of stdout
                line = begin
                  subj = NittyMail::Util.extract_subject(mail, raw, strict_errors: settings.strict_errors)
                  from = NittyMail::Util.safe_json(mail&.from, on_error: "encoding error for 'from' during logging; subject: #{subj}", strict_errors: settings.strict_errors)
                  suffix = begin
                    date = mail&.date
                    "sent on #{date}"
                  rescue Mail::Field::NilParseError, ArgumentError
                    raise if settings.strict_errors
                    "sent on unknown date"
                  end
                  "processing mail in mailbox #{mbox_name} with uid: #{uid} from #{from} and subject: #{subj} #{flags_json} #{suffix}"
                end
                progress&.event(:sync_log, {message: line})
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
              processed_count += 1
              # Progress is reported via events; no direct increments
            end
          end
          client.close
          progress&.event(:sync_worker_stopped, {mailbox: mbox_name, thread: Thread.current.object_id})
        rescue => e
          # Catch any unhandled exceptions in worker threads to prevent silent exits
          mailbox_abort = true
          progress&.event(:sync_log, {message: "FATAL: Worker thread crashed in mailbox '#{mbox_name}': #{e.class}: #{e.message}"})
          progress&.event(:sync_log, {message: "Backtrace:\n" + e.backtrace.join("\n")})
          # Re-raise to ensure the exception is visible if Thread.abort_on_exception is true
          error_count += 1
          raise e
        end
      end

      # Wait for all workers to complete and check for exceptions
      worker_exceptions = []
      workers.each do |worker|
        worker.join
      rescue => e
        worker_exceptions << e
        mailbox_abort = true
      end

      write_queue << :__DONE__

      # Wait for writer thread and check for exceptions
      begin
        writer.join
      rescue => e
        worker_exceptions << e
        mailbox_abort = true
      end

      # If we collected any exceptions, report them
      unless worker_exceptions.empty?
        progress&.event(:sync_log, {message: "Mailbox processing failed with #{worker_exceptions.size} thread exception(s)"})
        worker_exceptions.each_with_index do |e, i|
          progress&.event(:sync_log, {message: "Exception #{i + 1}: #{e.class}: #{e.message}"})
        end
        error_count += worker_exceptions.size
      end

      # Return mailbox summary stats
      {status: (mailbox_abort ? :aborted : :ok), processed: processed_count, errors: error_count}
    end
  end
end
