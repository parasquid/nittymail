# frozen_string_literal: true

require "spec_helper"

RSpec.describe NittyMail::Utils do
  describe ".progress_bar" do
    it "creates a progress bar with correct parameters" do
      progress = described_class.progress_bar(title: "Test", total: 100)
      expect(progress).to be_a(ProgressBar::Base)
      expect(progress.title).to eq("Test")
      expect(progress.total).to eq(100)
    end
  end
end
