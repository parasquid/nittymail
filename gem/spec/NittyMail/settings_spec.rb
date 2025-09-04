# frozen_string_literal: true

require "spec_helper"

RSpec.describe NittyMail::Settings do
  def with_modified_env(vars)
    old = {}
    vars.each do |k, v|
      old[k] = ENV[k]
      ENV[k] = v
    end
    yield
  ensure
    vars.each_key { |k| ENV[k] = old[k] }
  end

  context "defaults" do
    Around do |example|
      with_modified_env("IMAP_ADDRESS" => "env_user@example.com", "IMAP_PASSWORD" => "env_pass") do
        example.run
      end
    end

    Given(:settings) { described_class.new }
    Then { expect(settings.imap_url).to eq("imap.gmail.com") }
    And { expect(settings.imap_port).to eq(993) }
    And { expect(settings.imap_ssl).to eq(true) }
    And { expect(settings.imap_address).to eq("env_user@example.com") }
    And { expect(settings.imap_password).to eq("env_pass") }
  end

  context "overrides" do
    Around do |example|
      with_modified_env("IMAP_ADDRESS" => "env_user@example.com", "IMAP_PASSWORD" => "env_pass") do
        example.run
      end
    end

    Given(:custom_url) { "imap.example.com" }
    Given(:custom_port) { 143 }
    Given(:custom_ssl) { false }
    Given(:settings) { described_class.new(imap_url: custom_url, imap_port: custom_port, imap_ssl: custom_ssl) }
    Then { expect(settings.imap_url).to eq(custom_url) }
    And { expect(settings.imap_port).to eq(custom_port) }
    And { expect(settings.imap_ssl).to eq(custom_ssl) }
  end

  context "ENV variables" do
    context "used when not provided in options" do
      Around do |example|
        with_modified_env("IMAP_ADDRESS" => "env_addr@example.com", "IMAP_PASSWORD" => "env_pwd") do
          example.run
        end
      end

      Given(:settings) { described_class.new }
      Then { expect(settings.imap_address).to eq("env_addr@example.com") }
      And  { expect(settings.imap_password).to eq("env_pwd") }
    end

    context "ENV overrides explicit options for required keys" do
      Around do |example|
        with_modified_env("IMAP_ADDRESS" => "env_wins@example.com", "IMAP_PASSWORD" => "env_secret") do
          example.run
        end
      end

      Given(:settings) do
        described_class.new(imap_address: "opt_addr@example.com", imap_password: "opt_pwd")
      end

      Then { expect(settings.imap_address).to eq("env_wins@example.com") }
      And  { expect(settings.imap_password).to eq("env_secret") }
    end

    context "raises when required settings missing" do
      Around do |example|
        with_modified_env("IMAP_ADDRESS" => nil, "IMAP_PASSWORD" => nil) do
          example.run
        end
      end

      Then do
        expect { described_class.new }
          .to raise_error(ArgumentError, /Missing required options: imap_address, imap_password/)
      end
    end

    context "raises when required option set to nil" do
      Around do |example|
        with_modified_env("IMAP_ADDRESS" => nil, "IMAP_PASSWORD" => nil) do
          example.run
        end
      end

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
