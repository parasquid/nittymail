# frozen_string_literal: true

module NittyMail
  module Workers
    class Producer
      def initialize(settings:, mailbox_name:, address:, uidvalidity:, upload_batch_size:, fetch_queue:, job_queue:, interrupted:, on_error:)
        @settings = settings
        @mailbox_name = mailbox_name
        @address = address
        @uidvalidity = uidvalidity
        @upload_batch_size = upload_batch_size
        @fetch_queue = fetch_queue
        @job_queue = job_queue
        @interrupted = interrupted # -> bool
        @on_error = on_error       # -> proc(type, exception, uid_batch)
      end

      def start(threads: 1)
        count = threads.to_i
        count = 1 if count < 1
        Array.new(count) do
          Thread.new do
            mailbox_client = NittyMail::Mailbox.new(settings: @settings, mailbox_name: @mailbox_name)
            until @interrupted.call
              uid_batch = begin
                @fetch_queue.pop(true)
              rescue ThreadError
                break
              end

              begin
                fetch_response = mailbox_client.fetch(uids: uid_batch)
                doc_ids = []
                documents = []
                metadata_list = []
                fetch_response.each do |msg|
                  uid = msg.attr["UID"] || msg.attr[:UID] || msg.attr[:uid]
                  raw = msg.attr["BODY[]"] || msg.attr["BODY"] || msg.attr[:BODY] || msg.attr[:'BODY[]']
                  raw = raw.to_s.dup
                  raw.force_encoding("BINARY")
                  safe = raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
                  doc_ids << "#{@uidvalidity}:#{uid}"
                  documents << safe
                  metadata_list << {address: @address, mailbox: @mailbox_name, uidvalidity: @uidvalidity, uid: uid}
                end

                Array(doc_ids).each_slice(@upload_batch_size)
                  .zip(Array(documents).each_slice(@upload_batch_size), Array(metadata_list).each_slice(@upload_batch_size))
                  .each do |id_batch, doc_batch, meta_batch|
                    @job_queue << [id_batch, doc_batch, meta_batch]
                  end
              rescue Net::IMAP::NoResponseError, Net::IMAP::BadResponseError => e
                @on_error&.call(:imap, e, uid_batch)
              rescue => e
                @on_error&.call(:unexpected, e, uid_batch)
              end
            end
          end
        end
      end
    end
  end
end
