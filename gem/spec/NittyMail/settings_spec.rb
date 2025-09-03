# frozen_string_literal: true

require "spec_helper"

RSpec.describe NittyMail::Settings do
  context "defaults" do
    Given(:settings) { described_class.new }
    Then { expect(settings.imap_url).to eq("imap.gmail.com") }
    And { expect(settings.imap_port).to eq(993) }
    And { expect(settings.imap_ssl).to eq(true) }
  end

  context "overrides" do
    Given(:custom_url) { "imap.example.com" }
    Given(:custom_port) { 143 }
    Given(:custom_ssl) { false }
    Given(:settings) { described_class.new(imap_url: custom_url, imap_port: custom_port, imap_ssl: custom_ssl) }
    Then { expect(settings.imap_url).to eq(custom_url) }
    And { expect(settings.imap_port).to eq(custom_port) }
    And { expect(settings.imap_ssl).to eq(custom_ssl) }
  end
end
