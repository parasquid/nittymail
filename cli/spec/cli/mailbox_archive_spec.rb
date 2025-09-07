require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe "CLI mailbox archive" do
  Given(:address) { "test@example.com" }
  Given(:password) { "secret" }
  Given(:mailbox_stub) { double("NittyMail::Mailbox") }
  Given(:temp_dir) { Dir.mktmpdir }
  
  before do
    ENV["NITTYMAIL_IMAP_ADDRESS"] = address
    ENV["NITTYMAIL_IMAP_PASSWORD"] = password

    require_relative "../../commands/mailbox"

    # Stub nittymail Mailbox
    allow(NittyMail::Mailbox).to receive(:new).and_return(mailbox_stub)
    
    # Mock file operations to use temp directory
    allow(File).to receive(:expand_path).and_call_original
    allow(File).to receive(:expand_path).with("../../archives", anything).and_return(temp_dir)
    
    # Mock utility methods
    allow(NittyMail::Utils).to receive(:sanitize_collection_name) { |name| name.downcase }
  end

  after do
    # Clean up environment variables
    ENV.delete("NITTYMAIL_IMAP_ADDRESS") 
    ENV.delete("NITTYMAIL_IMAP_PASSWORD")
    
    # Clean up temp directory
    FileUtils.rm_rf(temp_dir) if temp_dir && Dir.exist?(temp_dir)
  end

  context "missing credentials" do
    before do
      ENV.delete("NITTYMAIL_IMAP_ADDRESS")
      ENV.delete("NITTYMAIL_IMAP_PASSWORD")
    end

    Then "raises ArgumentError for missing credentials" do
      mailbox_cmd = NittyMail::Commands::Mailbox.new
      expect { mailbox_cmd.invoke(:archive, [], {}) }.to raise_error(SystemExit)
    end
  end

  context "--only-preflight option" do
    before do
      allow(mailbox_stub).to receive(:preflight).and_return({
        uidvalidity: 123,
        to_fetch: [1, 2, 3, 4, 5],
        server_size: 5
      })
    end

    Then "lists UIDs without creating files" do
      mailbox_cmd = NittyMail::Commands::Mailbox.new
      
      expect { 
        mailbox_cmd.invoke(:archive, [], {only_preflight: true, output: temp_dir}) 
      }.to output(/UIDs: 1, 2, 3, 4, 5/).to_stdout
      
      # Verify no .eml files were created
      expect(Dir.glob("#{temp_dir}/**/*.eml")).to be_empty
    end

    Then "handles empty UID list" do
      allow(mailbox_stub).to receive(:preflight).and_return({
        uidvalidity: 123,
        to_fetch: [],
        server_size: 0
      })

      mailbox_cmd = NittyMail::Commands::Mailbox.new
      
      expect { 
        mailbox_cmd.invoke(:archive, [], {only_preflight: true, output: temp_dir}) 
      }.to output(/\(no UIDs found\)/).to_stdout
    end
  end

  context "--only-ids option" do
    let(:mock_message) do
      double("Message").tap do |msg|
        allow(msg).to receive(:attr).and_return({
          "UID" => 123,
          "BODY[]" => "From: test@example.com\r\nSubject: Test\r\n\r\nTest body",
          "X-GM-THRID" => "thread123",
          "X-GM-MSGID" => "msg123",
          "X-GM-LABELS" => ["INBOX", "Important"],
          "INTERNALDATE" => Time.now,
          "RFC822.SIZE" => 1024
        })
      end
    end

    before do
      allow(mailbox_stub).to receive(:preflight).and_return({
        uidvalidity: 123,
        to_fetch: [],  # Not used in --only-ids mode
        server_size: 0
      })
      allow(mailbox_stub).to receive(:fetch).and_return([mock_message])
      allow(NittyMail::Utils).to receive(:progress_bar).and_return(double("progress_bar", :progress= => nil, finish: nil, finished?: false))
    end

    Then "validates UIDs from comma-separated list" do
      mailbox_cmd = NittyMail::Commands::Mailbox.new
      
      expect { 
        mailbox_cmd.invoke(:archive, [], {only_ids: ["123,456,789"], output: temp_dir}) 
      }.to output(/specified UIDs: 123, 456, 789/).to_stdout
    end

    Then "handles invalid UIDs gracefully" do
      mailbox_cmd = NittyMail::Commands::Mailbox.new
      
      expect { 
        mailbox_cmd.invoke(:archive, [], {only_ids: ["abc,0,,789"], output: temp_dir}) 
      }.to output(/specified UIDs: 789/).to_stdout
    end

    Then "exits with error for empty UID list" do
      mailbox_cmd = NittyMail::Commands::Mailbox.new
      
      expect { 
        mailbox_cmd.invoke(:archive, [], {only_ids: ["abc,0,,"], output: temp_dir}) 
      }.to raise_error(SystemExit)
    end

    context "with existing files" do
      before do
        # Create existing .eml file
        uv_dir = File.join(temp_dir, address.downcase, "inbox", "123")
        FileUtils.mkdir_p(uv_dir)
        File.write(File.join(uv_dir, "123.eml"), "existing content")
      end

      Then "prompts for confirmation without --yes" do
        mailbox_cmd = NittyMail::Commands::Mailbox.new
        
        # Mock user input - decline
        allow(mailbox_cmd).to receive(:ask).with("Overwrite existing files? (y/N):").and_return("n")
        
        expect { 
          mailbox_cmd.invoke(:archive, [], {only_ids: ["123"], output: temp_dir}) 
        }.to output(/Archive cancelled/).to_stdout
      end

      Then "skips confirmation with --yes" do
        mailbox_cmd = NittyMail::Commands::Mailbox.new
        
        expect { 
          mailbox_cmd.invoke(:archive, [], {only_ids: ["123"], yes: true, output: temp_dir}) 
        }.not_to output(/Archive cancelled/).to_stdout
      end
    end
  end

  context "normal archive mode" do
    let(:mock_message) do
      double("Message").tap do |msg|
        allow(msg).to receive(:attr).and_return({
          "UID" => 1,
          "BODY[]" => "From: test@example.com\r\nSubject: Test\r\n\r\nTest body",
          "X-GM-THRID" => "thread1",
          "X-GM-MSGID" => "msg1",
          "X-GM-LABELS" => ["INBOX"],
          "INTERNALDATE" => Time.now,
          "RFC822.SIZE" => 512
        })
      end
    end

    before do
      allow(mailbox_stub).to receive(:preflight).and_return({
        uidvalidity: 123,
        to_fetch: [1, 2, 3],
        server_size: 3
      })
      allow(mailbox_stub).to receive(:fetch).and_return([mock_message])
      allow(NittyMail::Utils).to receive(:progress_bar).and_return(double("progress_bar", :progress= => nil, finish: nil, finished?: false))
    end

    Then "skips existing files in normal mode" do
      # Create existing file for UID 1
      uv_dir = File.join(temp_dir, address.downcase, "inbox", "123")
      FileUtils.mkdir_p(uv_dir)
      File.write(File.join(uv_dir, "1.eml"), "existing content")

      mailbox_cmd = NittyMail::Commands::Mailbox.new
      
      # Should only try to fetch UIDs 2 and 3
      expect(mailbox_stub).to receive(:fetch).with(uids: [2, 3]).and_return([])
      
      mailbox_cmd.invoke(:archive, [], {output: temp_dir})
    end

    Then "handles up-to-date folder gracefully" do
      # Create existing files for all UIDs
      uv_dir = File.join(temp_dir, address.downcase, "inbox", "123")
      FileUtils.mkdir_p(uv_dir)
      [1, 2, 3].each do |uid|
        File.write(File.join(uv_dir, "#{uid}.eml"), "existing content")
      end

      mailbox_cmd = NittyMail::Commands::Mailbox.new
      
      expect { 
        mailbox_cmd.invoke(:archive, [], {output: temp_dir}) 
      }.to output(/Nothing to archive. Folder is up to date/).to_stdout
    end
  end

  context "header preservation" do
    let(:mock_message_with_missing_headers) do
      double("Message").tap do |msg|
        allow(msg).to receive(:attr).and_return({
          "UID" => 1,
          "BODY[]" => "From: test@example.com\r\nSubject: Test\r\n\r\nTest body",
          "X-GM-THRID" => "thread123",
          "X-GM-MSGID" => "msg123",
          "X-GM-LABELS" => ["INBOX", "Important"],
          "INTERNALDATE" => Time.parse("2025-01-01 12:00:00 UTC"),
          "RFC822.SIZE" => 1024
        })
      end
    end

    before do
      allow(mailbox_stub).to receive(:preflight).and_return({
        uidvalidity: 123,
        to_fetch: [1],
        server_size: 1
      })
      allow(mailbox_stub).to receive(:fetch).and_return([mock_message_with_missing_headers])
      allow(NittyMail::Utils).to receive(:progress_bar).and_return(double("progress_bar", :progress= => nil, finish: nil, finished?: false))
    end

    Then "adds missing Gmail and IMAP headers" do
      mailbox_cmd = NittyMail::Commands::Mailbox.new
      mailbox_cmd.invoke(:archive, [], {output: temp_dir})
      
      # Check that the .eml file was created with headers
      eml_files = Dir.glob("#{temp_dir}/**/*.eml")
      expect(eml_files).not_to be_empty
      
      content = File.read(eml_files.first)
      expect(content).to include("X-GM-THRID: thread123")
      expect(content).to include("X-GM-MSGID: msg123") 
      expect(content).to include("X-GM-LABELS: INBOX Important")
      expect(content).to include("X-IMAP-INTERNALDATE:")
      expect(content).to include("X-RFC822-SIZE: 1024")
    end
  end
end