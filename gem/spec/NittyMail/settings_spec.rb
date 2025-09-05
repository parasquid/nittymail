# frozen_string_literal: true

require "spec_helper"

RSpec.describe NittyMail::Settings do
  context "defaults" do
    Given(:settings) { described_class.new(imap_address: "user@example.com", imap_password: "secret") }
    Then { expect(settings.imap_url).to eq("imap.gmail.com") }
    And  { expect(settings.imap_port).to eq(993) }
    And  { expect(settings.imap_ssl).to eq(true) }
  end

  context "overrides" do
    Given(:custom_url) { "imap.example.com" }
    Given(:custom_port) { 143 }
    Given(:custom_ssl) { false }
    Given(:settings) do
      described_class.new(
        imap_address: "user@example.com",
        imap_password: "secret",
        imap_url: custom_url,
        imap_port: custom_port,
        imap_ssl: custom_ssl
      )
    end
    Then { expect(settings.imap_url).to eq(custom_url) }
    And  { expect(settings.imap_port).to eq(custom_port) }
    And  { expect(settings.imap_ssl).to eq(custom_ssl) }
  end

  context "validation" do
    context "raises when required settings missing" do
      Then do
        expect { described_class.new }
          .to raise_error(ArgumentError, /Missing required options: imap_address, imap_password/)
      end
    end

    context "raises when required option set to nil" do
      Then do
        expect { described_class.new(imap_address: nil, imap_password: "x") }
          .to raise_error(ArgumentError, /Required option is nil: imap_address/)
      end

      And do
        expect { described_class.new(imap_address: "x", imap_password: nil) }
          .to raise_error(ArgumentError, /Required option is nil: imap_password/)
      end
    end
  end
end
