require "time"
require "mail"
require "reverse_markdown"

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
                  internal = msg.attr["INTERNALDATE"] || msg.attr[:INTERNALDATE] || msg.attr[:internaldate]
                  internal_epoch = (internal.is_a?(Time) ? internal.to_i : (begin
                    require "time"
                    Time.parse(internal.to_s).to_i
                  rescue ArgumentError
                    0
                  end))
                  # Envelope FROM email
                  envelope = msg.attr["ENVELOPE"] || msg.attr[:ENVELOPE] || msg.attr[:envelope]
                  from_email = begin
                    addrs = envelope&.from
                    addr = Array(addrs).first
                    m = addr&.mailbox&.to_s
                    h = addr&.host&.to_s
                    (m && h && !m.empty? && !h.empty?) ? "#{m}@#{h}".downcase : nil
                  rescue
                    nil
                  end
                  # Gmail labels
                  labels_attr = msg.attr["X-GM-LABELS"] || msg.attr[:'X-GM-LABELS'] || msg.attr[:'X-GM-LABELS'] || msg.attr[:x_gm_labels]
                  labels = Array(labels_attr).map { |v| v.to_s }
                  # RFC822.SIZE
                  size_attr = msg.attr["RFC822.SIZE"] || msg.attr[:'RFC822.SIZE'] || msg.attr[:'RFC822.SIZE']
                  rfc822_size = size_attr.to_i
                  # Build base (raw) embedding
                  doc_ids << "#{@uidvalidity}:#{uid}"
                  documents << safe
                  base_meta = {
                    address: @address,
                    mailbox: @mailbox_name,
                    uidvalidity: @uidvalidity,
                    uid: uid,
                    internaldate_epoch: internal_epoch,
                    from_email: from_email,
                    rfc822_size: rfc822_size,
                    labels: labels,
                    item_type: "raw"
                  }
                  metadata_list << base_meta

                  # Parse email for subject/body
                  mail = begin
                    ::Mail.read_from_string(safe)
                  rescue
                    nil
                  end
                  if mail
                    subject = mail.subject.to_s
                    # Prefer text part; fallback to decoded body
                    text_part = mail.text_part&.decoded
                    html_part = mail.html_part&.decoded
                    plain_text = (text_part && text_part.to_s.strip != "") ? text_part.to_s : mail.body.to_s
                    markdown = if html_part && html_part.to_s.strip != ""
                      ::ReverseMarkdown.convert(html_part.to_s)
                    else
                      ::ReverseMarkdown.convert(plain_text.to_s)
                    end

                    # Subject embedding
                    unless subject.to_s.strip.empty?
                      doc_ids << "#{@uidvalidity}:#{uid}:subject"
                      documents << subject.to_s
                      metadata_list << base_meta.merge(item_type: "subject")
                    end

                    # Plain text embedding
                    unless plain_text.to_s.strip.empty?
                      doc_ids << "#{@uidvalidity}:#{uid}:text"
                      documents << plain_text.to_s
                      metadata_list << base_meta.merge(item_type: "plain_text")
                    end

                    # Markdown embedding
                    unless markdown.to_s.strip.empty?
                      doc_ids << "#{@uidvalidity}:#{uid}:markdown"
                      documents << markdown.to_s
                      metadata_list << base_meta.merge(item_type: "markdown")
                    end
                  end
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
