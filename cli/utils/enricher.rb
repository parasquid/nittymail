# frozen_string_literal: true

require "mail"
require "reverse_markdown"

module NittyMail
  module Enricher
    module_function

    # Build additional embeddings (subject/plain_text/markdown) from a raw RFC822 message.
    # Returns arrays: [ids, docs, metas]
    def variants_for(raw:, base_meta:, uidvalidity:, uid:, raise_on_error: false)
      ids = []
      docs = []
      metas = []

      safe = (begin
        x = raw.to_s.dup
        x.force_encoding("BINARY")
        x.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
      rescue
        raw.to_s
      end)
      mail = (begin; ::Mail.read_from_string(safe); rescue; nil; end)
      return [ids, docs, metas] unless mail

      subject = mail.subject.to_s
      text_part = mail.text_part&.decoded
      html_part = mail.html_part&.decoded
      plain_text = (text_part && !text_part.to_s.strip.empty?) ? text_part.to_s : mail.body.to_s
      markdown = (begin
        if html_part && !html_part.to_s.strip.empty?
          ::ReverseMarkdown.convert(html_part.to_s)
        else
          ::ReverseMarkdown.convert(plain_text.to_s)
        end
      rescue
        plain_text.to_s
      end)

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

    def self.normalize_utf8(str)
      s = str.to_s.dup
      s.force_encoding("BINARY")
      s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
    rescue
      str.to_s
    end
  end
end
