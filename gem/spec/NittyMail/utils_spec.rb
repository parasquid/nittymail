# frozen_string_literal: true

require "spec_helper"

RSpec.describe NittyMail::Utils do
  describe ".sanitize_collection_name" do
    context "with valid input" do
      it "converts spaces to dashes" do
        expect(described_class.sanitize_collection_name("My Folder")).to eq("my-folder")
      end

      it "converts uppercase to lowercase" do
        expect(described_class.sanitize_collection_name("INBOX")).to eq("inbox")
      end

      it "removes special characters" do
        expect(described_class.sanitize_collection_name("Test@#$%")).to eq("test")
      end

      it "handles Gmail-style mailbox names" do
        expect(described_class.sanitize_collection_name("[Gmail]/Sent Mail")).to eq("gmail-sent-mail")
      end

      it "collapses multiple dashes" do
        expect(described_class.sanitize_collection_name("a--b")).to eq("a-b")
      end

      it "trims leading/trailing dashes" do
        expect(described_class.sanitize_collection_name("-test-")).to eq("test")
      end

      it "handles empty string" do
        expect(described_class.sanitize_collection_name("")).to eq("nm")
      end

      it "handles nil input" do
        expect(described_class.sanitize_collection_name(nil)).to eq("nm")
      end

      it "ensures minimum length" do
        expect(described_class.sanitize_collection_name("a")).to eq("nm")
      end

      it "truncates long names" do
        long_name = "a" * 100
        result = described_class.sanitize_collection_name(long_name)
        expect(result.length).to be <= 63
        expect(result).to start_with("a")
      end
    end
  end

  describe ".progress_bar" do
    it "creates a progress bar with correct parameters" do
      progress = described_class.progress_bar(title: "Test", total: 100)
      expect(progress).to be_a(ProgressBar::Base)
      expect(progress.title).to eq("Test")
      expect(progress.total).to eq(100)
    end
  end
end
