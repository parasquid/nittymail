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
      rescue => e
        warn "enrich normalize error: #{e.class}: #{e.message} uidvalidity=#{uidvalidity} uid=#{uid}"
        raw.to_s
      end)
      mail = begin
        ::Mail.read_from_string(safe)
      rescue => e
        if raise_on_error
          raise e
        else
          warn "enrich parse error: #{e.class}: #{e.message} uidvalidity=#{uidvalidity} uid=#{uid}"
          nil
        end
      end
      return [ids, docs, metas] unless mail

      subject = mail.subject.to_s
      text_part = NittyMail::Enricher.safe_decode(mail.text_part)
      html_part = NittyMail::Enricher.safe_decode(mail.html_part)
      body_fallback = NittyMail::Enricher.safe_decode(mail.body)
      plain_text = text_part.to_s.strip.empty? ? body_fallback.to_s : text_part.to_s
      markdown = (begin
        if html_part && !html_part.to_s.strip.empty?
          ::ReverseMarkdown.convert(html_part.to_s)
        else
          ::ReverseMarkdown.convert(plain_text.to_s)
        end
      rescue => e
        if raise_on_error
          raise e
        else
          warn "enrich markdown conversion error: #{e.class}: #{e.message} uidvalidity=#{uidvalidity} uid=#{uid}"
          plain_text.to_s
        end
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
    rescue => e
      warn "enrich normalize_utf8 error: #{e.class}: #{e.message}"
      str.to_s
    end

    def self.safe_decode(part)
      return "" unless part
      begin
        if part.respond_to?(:decoded)
          part.decoded
        elsif part.respond_to?(:body) && part.body.respond_to?(:decoded)
          part.body.decoded
        else
          part.to_s
        end
      rescue ::Mail::UnknownEncodingType => e
        warn "enrich decode error: #{e.class}: #{e.message} (UnknownEncodingType). Using raw body."
        part.respond_to?(:body) ? part.body.to_s : part.to_s
      rescue StandardError => e
        warn "enrich decode error: #{e.class}: #{e.message}. Using raw body."
        part.respond_to?(:body) ? part.body.to_s : part.to_s
      end
    end
  end
end
