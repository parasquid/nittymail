# frozen_string_literal: true

require "spec_helper"

RSpec.describe NittyMail::VERSION do
  Then { expect(subject).not_to be_nil }
  And { expect(subject).to be_a(String) }
end
