require_relative "../lib/nittymail/logging"
require_relative "spec_helper"

RSpec.describe NittyMail::Logging do
  context "when no UIDs" do
    Given(:uids) { [] }
    Then { expect(NittyMail::Logging.format_uids_preview(uids)).to eq("uids to be synced: []") }
  end

  context "when 3 UIDs" do
    Given(:uids) { [101, 202, 303] }
    Then { expect(NittyMail::Logging.format_uids_preview(uids)).to eq("uids to be synced: [101, 202, 303]") }
  end

  context "when 5 UIDs" do
    Given(:uids) { [1, 2, 3, 4, 5] }
    Then { expect(NittyMail::Logging.format_uids_preview(uids)).to eq("uids to be synced: [1, 2, 3, 4, 5]") }
  end

  context "when more than 5 UIDs" do
    Given(:uids) { [1, 2, 3, 4, 5, 6, 7, 8] }
    Then { expect(NittyMail::Logging.format_uids_preview(uids)).to eq("uids to be synced: [1, 2, 3, 4, 5, ... (3 more uids)]") }
  end
end
