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

require "nokogiri"
require "cgi"
require "reverse_markdown"

module NittyMail
  module Util
    module_function

    # Encode any string-ish value to UTF-8 safely, replacing invalid/undef bytes
    def safe_utf8(value)
      s = value.to_s
      s = s.dup if s.frozen?
      s.encode("UTF-8", "binary", invalid: :replace, undef: :replace, replace: "")
    end

    # Convert HTML to Markdown using reverse_markdown after removing script/style
    def html_to_markdown(html)
      h = safe_utf8(html.to_s)
      begin
        doc = Nokogiri::HTML::DocumentFragment.parse(h)
        doc.css("script,style").remove
        cleaned = doc.to_html
        md = ReverseMarkdown.convert(cleaned, unknown_tags: :drop)
        # Normalize entities and whitespace: convert &nbsp; to space, collapse runs of spaces/tabs
        # Some libraries leave non-breaking spaces as literal entities; normalize both forms.
        s = md.gsub(/&nbsp;/i, " ")
        s = CGI.unescapeHTML(s)
        s = s.tr("\u00A0", " ")
        s = s.gsub(/[ \t]+/, " ")
        # Remove simple Markdown emphasis markers introduced by ReverseMarkdown
        s = s.gsub(/\*\*(.+?)\*\*/, "\\1").gsub(/\*(.+?)\*/, "\\1").gsub(/__(.+?)__/, "\\1")
        s.strip
      rescue => _
        # Fallback: plain text if conversion fails
        s = h.gsub(/<[^>]+>/, " ")
        s = s.gsub(/&nbsp;/i, " ")
        s = CGI.unescapeHTML(s)
        s = s.tr("\u00A0", " ")
        s = s.gsub(/[ \t]+/, " ")
        s = s.gsub(/\*\*(.+?)\*\*/, "\\1").gsub(/\*(.+?)\*/, "\\1").gsub(/__(.+?)__/, "\\1")
        s.strip
      end
    end

    # Extract a Markdown/plain body suitable for embedding/search.
    # Preference order: text_part -> html_part (markdown) -> whole body (markdown when HTML-like)
    def extract_plain_text(mail)
      return "" if mail.nil?
      # Prefer explicit text part when present
      part = mail&.text_part&.decoded
      if part && !part.empty?
        return normalize_text_plain(part)
      end

      # Otherwise use HTML part converted to text
      html = mail&.html_part&.decoded
      if html && !html.empty?
        return html_to_markdown(html)
      end

      # Fallback to the full body
      body = mail&.body&.decoded
      body_str = safe_utf8(body)
      if body_str.include?("<") && body_str.include?(">")
        html_to_markdown(body_str)
      else
        normalize_text_plain(body_str)
      end
    end

    # Preserve line breaks for text/plain while tidying whitespace.
    # - Normalize CRLF to LF
    # - Strip trailing spaces per line
    # - Collapse 3+ blank lines to 2
    def normalize_text_plain(text)
      s = safe_utf8(text.to_s)
      s = s.gsub("\r\n", "\n").tr("\r", "\n")
      s = s.lines.map { |ln| ln.rstrip }.join("\n")
      s = s.gsub(/\n{3,}/, "\n\n")
      s.strip
    end

    # JSON-encode an Array or scalar after UTF-8 sanitization; never raise
    def safe_json(value, on_error: nil, strict_errors: false)
      if value.is_a?(Array)
        value.map { |v| safe_utf8(v) }.to_json
      else
        safe_utf8(value).to_json
      end
    rescue JSON::GeneratorError, ArgumentError, Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      raise if strict_errors
      warn(on_error) if on_error
      value.is_a?(Array) ? "[]" : "\"\""
    end

    # Parse raw RFC822/IMAP payload into a Mail object safely.
    # Returns a Mail::Message or raises the last parse error.
    def parse_mail_safely(raw, mbox_name:, uid:)
      str = raw.to_s
      # 1) Try as binary bytes
      begin
        return Mail.read_from_string(str.b)
      rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError => e1
        warn "mail parse error (binary) mailbox=#{mbox_name} uid=#{uid}: #{e1.class}: #{e1.message}; retrying with UTF-8 sanitized"
        last_error = e1
      end

      # 2) Try as sanitized UTF-8 (replace invalid/undef)
      begin
        sanitized = safe_utf8(str)
        return Mail.read_from_string(sanitized)
      rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError => e2
        warn "mail parse error (sanitized UTF-8) mailbox=#{mbox_name} uid=#{uid}: #{e2.class}: #{e2.message}; retrying with scrubbed UTF-8"
        last_error = e2
      end

      # 3) Try scrubbed UTF-8 (replace problematic sequences)
      begin
        scrubbed = str.dup.force_encoding("UTF-8").scrub
        return Mail.read_from_string(scrubbed)
      rescue => e3
        warn "mail parse error (scrubbed) mailbox=#{mbox_name} uid=#{uid}: #{e3.class}: #{e3.message}; retrying with header sanitization"
        last_error = e3
      end

      # 4) Try with header sanitization for HTML fragments in headers
      begin
        header_sanitized = sanitize_email_headers(str)
        return Mail.read_from_string(header_sanitized)
      rescue => e4
        warn "mail parse error (header sanitized) mailbox=#{mbox_name} uid=#{uid}: #{e4.class}: #{e4.message}; rethrowing"
        last_error = e4
      end

      raise(last_error || ArgumentError.new("unparseable message for mailbox=#{mbox_name} uid=#{uid}"))
    end

    # Best-effort subject extraction without tripping on bad bytes
    def extract_subject(mail, raw, strict_errors: false)
      begin
        return safe_utf8(mail&.subject)
      rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        raise if strict_errors
        # fall through to raw
      end
      headers = raw.to_s.split(/\r?\n\r?\n/, 2).first.to_s
      m = headers.match(/^Subject:\s*(.*?)(?:\r?\n(?![ \t])|\z)/m)
      subj = m ? m[1].gsub(/\r?\n[ \t]+/, " ").strip : ""
      safe_utf8(subj)
    end

    # Sanitize email headers by removing/escaping HTML fragments that confuse Mail gem
    def sanitize_email_headers(email_string)
      # Split email into headers and body
      parts = email_string.split(/\r?\n\r?\n/, 2)
      headers = parts[0] || ""
      body = parts[1] || ""

      # Process header lines individually to preserve valid headers
      header_lines = headers.split(/\r?\n/)
      sanitized_lines = []

      header_lines.each do |line|
        # Skip lines that start with HTML tags (these aren't valid headers)
        if line.strip.match?(/^<[^>]+>/)
          # This is likely HTML masquerading as a header line, skip it
          next
        end

        # For lines that contain HTML but might be valid headers, clean them up
        if line.include?("<") && line.include?(">")
          # Remove HTML tags but preserve the rest of the line structure
          cleaned_line = line.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip
          # Only keep it if it still looks like a valid header (contains :)
          sanitized_lines << cleaned_line if cleaned_line.include?(":")
        else
          # Line doesn't contain HTML, keep as-is
          sanitized_lines << line
        end
      end

      sanitized_headers = sanitized_lines.join("\r\n")

      # Reconstruct email with sanitized headers
      if body.empty?
        sanitized_headers
      else
        "#{sanitized_headers}\r\n\r\n#{body}"
      end
    end
  end
end
