# frozen_string_literal: true

require "mail"
require "reverse_markdown"

module NittyMail
  module Enricher
    module_function

    # Build additional embeddings (subject/plain_text/markdown) from a raw RFC822 message.
    # Returns arrays: [ids, docs, metas]
    def variants_for(raw:, base_meta:, uidvalidity:, uid:)
      ids = []
      docs = []
      metas = []

      mail = begin
        ::Mail.read_from_string(raw.to_s)
      rescue
        nil
      end
      return [ids, docs, metas] unless mail

      subject = mail.subject.to_s
      text_part = mail.text_part&.decoded
      html_part = mail.html_part&.decoded
      plain_text = (text_part && !text_part.to_s.strip.empty?) ? text_part.to_s : mail.body.to_s
      markdown = if html_part && !html_part.to_s.strip.empty?
        ::ReverseMarkdown.convert(html_part.to_s)
      else
        ::ReverseMarkdown.convert(plain_text.to_s)
      end

      unless subject.to_s.strip.empty?
        ids << "#{uidvalidity}:#{uid}:subject"
        docs << subject.to_s
        metas << base_meta.merge(item_type: "subject")
      end

      unless plain_text.to_s.strip.empty?
        ids << "#{uidvalidity}:#{uid}:text"
        docs << plain_text.to_s
        metas << base_meta.merge(item_type: "plain_text")
      end

      unless markdown.to_s.strip.empty?
        ids << "#{uidvalidity}:#{uid}:markdown"
        docs << markdown.to_s
        metas << base_meta.merge(item_type: "markdown")
      end

      [ids, docs, metas]
    end
  end
end
