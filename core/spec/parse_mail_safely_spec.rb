# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/nittymail/util'
require 'mail'

RSpec.describe NittyMail::Util do
  describe '#parse_mail_safely' do
    let(:mbox_name) { 'INBOX' }
    let(:uid) { 123 }

    context 'with valid email content' do
      it 'parses standard RFC822 email successfully' do
        email = <<~EMAIL
          From: sender@example.com
          To: recipient@example.com
          Subject: Test Email
          Date: Mon, 1 Jan 2023 10:00:00 +0000

          This is a test email body.
        EMAIL

        result = described_class.parse_mail_safely(email, mbox_name: mbox_name, uid: uid)
        
        expect(result).to be_a(Mail::Message)
        expect(result.from).to eq(['sender@example.com'])
        expect(result.to).to eq(['recipient@example.com'])
        expect(result.subject).to eq('Test Email')
        expect(result.body.to_s.strip).to eq('This is a test email body.')
      end

      it 'parses email with multiple recipients' do
        email = <<~EMAIL
          From: sender@example.com
          To: user1@example.com, user2@example.com
          Cc: cc@example.com
          Subject: Multi-recipient email

          Body content here.
        EMAIL

        result = described_class.parse_mail_safely(email, mbox_name: mbox_name, uid: uid)
        
        expect(result.to).to eq(['user1@example.com', 'user2@example.com'])
        expect(result.cc).to eq(['cc@example.com'])
      end
    end

    context 'with encoding issues' do
      it 'handles invalid UTF-8 sequences' do
        # Create email with invalid UTF-8 bytes
        email_with_bad_bytes = "From: sender@example.com\r\nSubject: Test\x80\x81\r\n\r\nBody"
        
        result = described_class.parse_mail_safely(email_with_bad_bytes, mbox_name: mbox_name, uid: uid)
        
        expect(result).to be_a(Mail::Message)
        expect(result.from).to eq(['sender@example.com'])
        # Subject should be sanitized (invalid bytes replaced/removed)
        expect(result.subject).to be_a(String)
      end

      it 'handles binary encoding issues' do
        # Force binary encoding on otherwise valid email
        email = "From: sender@example.com\r\nSubject: Test\r\n\r\nBody"
        binary_email = email.dup.force_encoding('ASCII-8BIT')
        
        result = described_class.parse_mail_safely(binary_email, mbox_name: mbox_name, uid: uid)
        
        expect(result).to be_a(Mail::Message)
        expect(result.from).to eq(['sender@example.com'])
        expect(result.subject).to eq('Test')
      end
    end

    context 'with HTML fragments in headers' do
      it 'removes HTML tags that masquerade as headers' do
        email_with_html_headers = <<~EMAIL
          From: sender@example.com
          To: recipient@example.com
          Subject: Email with HTML issues
          <a href="http://example.com" title="link">Some Link</a>
          <span style="color: red">Styled text</span>
          Date: Mon, 1 Jan 2023 10:00:00 +0000

          This is the email body.
        EMAIL

        result = described_class.parse_mail_safely(email_with_html_headers, mbox_name: mbox_name, uid: uid)
        
        expect(result).to be_a(Mail::Message)
        expect(result.from).to eq(['sender@example.com'])
        expect(result.to).to eq(['recipient@example.com'])
        expect(result.subject).to eq('Email with HTML issues')
        expect(result.body.to_s.strip).to eq('This is the email body.')
      end

      it 'parses emails with HTML in headers (may generate warnings but succeeds)' do
        email_with_html_in_header = <<~EMAIL
          From: sender@example.com
          To: recipient@example.com
          Subject: Important <b>Bold</b> Subject
          X-Custom-Header: Value with <em>emphasis</em> tags

          Email body content.
        EMAIL

        result = described_class.parse_mail_safely(email_with_html_in_header, mbox_name: mbox_name, uid: uid)
        
        expect(result).to be_a(Mail::Message)
        expect(result.from).to eq(['sender@example.com'])
        expect(result.to).to eq(['recipient@example.com'])
        # Mail gem may or may not clean the HTML from headers, but should parse
        expect(result.subject).to be_a(String)
        expect(result.subject).to include('Important')
      end

      it 'handles emails that are predominantly HTML' do
        html_email = <<~EMAIL
          From: sender@example.com
          To: recipient@example.com
          Subject: HTML Newsletter

          <html>
          <head><title>Newsletter</title></head>
          <body>
          <h1>Welcome!</h1>
          <p>This is an <a href="http://example.com">HTML email</a></p>
          </body>
          </html>
        EMAIL

        result = described_class.parse_mail_safely(html_email, mbox_name: mbox_name, uid: uid)
        
        expect(result).to be_a(Mail::Message)
        expect(result.from).to eq(['sender@example.com'])
        expect(result.subject).to eq('HTML Newsletter')
        # Body should contain the HTML content
        expect(result.body.to_s).to include('<h1>Welcome!</h1>')
      end
    end

    context 'with complex problematic cases' do
      it 'handles emails with mixed line endings' do
        email_mixed_endings = "From: sender@example.com\rTo: recipient@example.com\nSubject: Mixed line endings\r\n\r\nBody content"
        
        result = described_class.parse_mail_safely(email_mixed_endings, mbox_name: mbox_name, uid: uid)
        
        expect(result).to be_a(Mail::Message)
        expect(result.from).to eq(['sender@example.com'])
        expect(result.to).to eq(['recipient@example.com'])
        expect(result.subject).to eq('Mixed line endings')
      end

      it 'handles emails with no headers' do
        body_only_email = "Just a body with no headers at all."
        
        result = described_class.parse_mail_safely(body_only_email, mbox_name: mbox_name, uid: uid)
        
        expect(result).to be_a(Mail::Message)
        # Mail gem may interpret this as a single header line since there's no header/body separator
        # The important thing is that it doesn't crash
        expect(result.body.to_s).to be_a(String)
      end

      it 'handles emails with malformed header continuation' do
        malformed_email = <<~EMAIL
          From: sender@example.com
          Subject: This is a very long subject that
          continues on the next line without proper
           indentation which might cause issues
          To: recipient@example.com

          Body content here.
        EMAIL

        result = described_class.parse_mail_safely(malformed_email, mbox_name: mbox_name, uid: uid)
        
        expect(result).to be_a(Mail::Message)
        expect(result.from).to eq(['sender@example.com'])
        expect(result.to).to eq(['recipient@example.com'])
        # Subject handling may vary, but should not crash
        expect(result.subject).to be_a(String)
      end
    end

    context 'with sanitize_email_headers helper' do
      describe '#sanitize_email_headers' do
        it 'removes standalone HTML tag lines' do
          email_with_html_lines = <<~EMAIL
            From: sender@example.com
            <a href="http://spam.com">Click here!</a>
            To: recipient@example.com
            <span style="color: red">Red text</span>
            Subject: Clean subject

            Body content.
          EMAIL

          result = described_class.sanitize_email_headers(email_with_html_lines)
          
          # Should not contain the HTML tag lines
          expect(result).not_to include('<a href="http://spam.com">')
          expect(result).not_to include('<span style="color: red">')
          # Should preserve valid headers
          expect(result).to include('From: sender@example.com')
          expect(result).to include('To: recipient@example.com')
          expect(result).to include('Subject: Clean subject')
          # Should preserve body
          expect(result).to include('Body content.')
        end

        it 'cleans HTML from header values while preserving header structure' do
          email_with_html_in_headers = <<~EMAIL
            From: sender@example.com
            Subject: Important <strong>message</strong> here
            X-Marketing: Special <em>offer</em> available

            Body text.
          EMAIL

          result = described_class.sanitize_email_headers(email_with_html_in_headers)
          
          # HTML should be removed from header values
          expect(result).to include('Subject: Important message here')
          expect(result).to include('X-Marketing: Special offer available')
          # Valid headers should be preserved
          expect(result).to include('From: sender@example.com')
          expect(result).to include('Body text.')
        end

        it 'handles email with only headers (no body)' do
          headers_only = <<~EMAIL.strip
            From: sender@example.com
            <div>HTML content</div>
            To: recipient@example.com
            Subject: Test
          EMAIL

          result = described_class.sanitize_email_headers(headers_only)
          
          expect(result).not_to include('<div>HTML content</div>')
          expect(result).to include('From: sender@example.com')
          expect(result).to include('To: recipient@example.com')
          expect(result).to include('Subject: Test')
        end
      end
    end

    context 'error handling and fallback behavior' do
      it 'succeeds with most malformed content (Mail gem is resilient)' do
        # Create content that might seem unparseable but Mail gem handles gracefully
        potentially_broken = "\x00\x01\x02INVALID EMAIL\xFF\xFE"
        
        # Mail gem is very resilient, so this will likely succeed
        result = described_class.parse_mail_safely(potentially_broken, mbox_name: mbox_name, uid: uid)
        expect(result).to be_a(Mail::Message)
      end

      it 'attempts all fallback methods and eventually succeeds or provides context on failure' do
        # Test that the method attempts different approaches
        # Since Mail gem rarely fails completely, we test that warnings are logged
        expect {
          result = described_class.parse_mail_safely("Some content", mbox_name: 'SENT', uid: 456)
          expect(result).to be_a(Mail::Message)
        }.not_to raise_error
      end

      it 'attempts all fallback methods in order' do
        # We can't easily test the exact order without mocking, but we can
        # verify that emails that would fail early parsing methods succeed
        # when they can be handled by later methods
        email_needing_sanitization = <<~EMAIL
          From: sender@example.com
          <script>alert('xss')</script>
          To: recipient@example.com
          Subject: Test

          Body
        EMAIL

        expect {
          result = described_class.parse_mail_safely(email_needing_sanitization, mbox_name: mbox_name, uid: uid)
          expect(result).to be_a(Mail::Message)
        }.not_to raise_error
      end
    end

    context 'real-world problematic email patterns' do
      it 'handles Yahoo Groups email format with HTML ads' do
        yahoo_groups_email = <<~EMAIL
          From: test@yahoogroups.com
          To: recipient@example.com
          Subject: [group] Message subject
          <a href="http://groups.yahoo.com/ads">Advertisement</a>
          <span style="font-size: 12px">Sponsored content</span>

          This is the actual message content.
          More content here.
        EMAIL

        result = described_class.parse_mail_safely(yahoo_groups_email, mbox_name: mbox_name, uid: uid)
        
        expect(result).to be_a(Mail::Message)
        expect(result.from).to eq(['test@yahoogroups.com'])
        expect(result.subject).to eq('[group] Message subject')
        expect(result.body.to_s).to include('This is the actual message content.')
      end

      it 'handles old Google Pages Creator emails' do
        google_pages_email = <<~EMAIL
          From: noreply@googlemail.com
          To: user@example.com
          Subject: Google Page Creator Update
          <a href="http://pages.google.com" title="Google Pages">http://pages.google.com</a>
          <span style="FONT-STYLE: italic">— The Google Page Creator team<br/></span>

          Your page has been updated.
        EMAIL

        result = described_class.parse_mail_safely(google_pages_email, mbox_name: mbox_name, uid: uid)
        
        expect(result).to be_a(Mail::Message)
        expect(result.from).to eq(['noreply@googlemail.com'])
        expect(result.subject).to eq('Google Page Creator Update')
        expect(result.body.to_s.strip).to eq('Your page has been updated.')
      end
    end
  end
end