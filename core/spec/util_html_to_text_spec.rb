require "spec_helper"
require "rspec/given"

require_relative "../lib/nittymail/util"
require "mail"

RSpec.describe NittyMail::Util do
  describe ".html_to_markdown" do
    Given(:html) { "<div>Hello <b>world</b>!<br><span>Line 2</span></div>" }
    When(:text) { described_class.html_to_markdown(html) }
    Then { text.include?("Hello") }
    Then { text.downcase.include?("world") }
    Then { text.gsub("\n", " ").include?("Line 2") }

    context "with script and style tags" do
      Given(:html) do
        <<~HTML
          <html>
            <head>
              <style>body { color: red; }</style>
              <script>console.log('x')</script>
            </head>
            <body>
              <p>Keep this.</p>
              <script>var a = 1;</script>
              <style>.x{}</style>
            </body>
          </html>
        HTML
      end
      When(:text) { described_class.html_to_markdown(html) }
      Then { text.include?("Keep this.") }
      Then { !text.include?("console.log") }
      Then { !text.include?("var a = 1") }
      Then { !text.include?(".x{") }
    end

    context "with excessive whitespace and HTML entities" do
      Given(:html) { "<p>&nbsp;Hello&nbsp;&nbsp; &amp;  goodbye</p>" }
      When(:text) { described_class.html_to_markdown(html) }
      Then { text == "Hello & goodbye" }
    end
  end

  describe ".extract_plain_text" do
    context "when text part is present" do
      Given(:raw) do
        <<~MAIL
          From: a@example.com
          To: b@example.com
          Subject: Test
          MIME-Version: 1.0
          Content-Type: multipart/alternative; boundary=bound

          --bound
          Content-Type: text/plain; charset=UTF-8

          Plain text line.
          --bound
          Content-Type: text/html; charset=UTF-8

          <div><b>HTML</b> version</div>
          --bound--
        MAIL
      end
      Given(:mail) { Mail.read_from_string(raw) }
      When(:text) { described_class.extract_plain_text(mail) }
      Then { text == "Plain text line." }
    end

    context "when only html part is present" do
      Given(:raw) do
        <<~MAIL
          From: a@example.com
          To: b@example.com
          Subject: Test
          MIME-Version: 1.0
          Content-Type: multipart/alternative; boundary=bound

          --bound
          Content-Type: text/html; charset=UTF-8

          <div><b>HTML</b> version <script>ignore()</script></div>
          --bound--
        MAIL
      end
      Given(:mail) { Mail.read_from_string(raw) }
      When(:text) { described_class.extract_plain_text(mail) }
      Then { text.downcase.include?("html version") }
    end

    context "when body contains inline HTML but no parts" do
      Given(:raw) do
        <<~MAIL
          From: a@example.com
          To: b@example.com
          Subject: Test
          MIME-Version: 1.0
          Content-Type: text/html; charset=UTF-8

          <p>Hello <i>world</i></p>
        MAIL
      end
      Given(:mail) { Mail.read_from_string(raw) }
      When(:text) { described_class.extract_plain_text(mail) }
      Then { text.downcase.include?("hello") }
      Then { text.downcase.include?("world") }
    end
  end
end
