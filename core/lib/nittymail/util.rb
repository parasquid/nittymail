# frozen_string_literal: true

module NittyMail
  module Util
    module_function

    # Encode any string-ish value to UTF-8 safely, replacing invalid/undef bytes
    def safe_utf8(value)
      s = value.to_s
      s = s.dup if s.frozen?
      s.encode("UTF-8", "binary", invalid: :replace, undef: :replace, replace: "")
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
        if line.include?('<') && line.include?('>')
          # Remove HTML tags but preserve the rest of the line structure
          cleaned_line = line.gsub(/<[^>]*>/, ' ').gsub(/\s+/, ' ').strip
          # Only keep it if it still looks like a valid header (contains :)
          sanitized_lines << cleaned_line if cleaned_line.include?(':')
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
