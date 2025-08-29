require_relative "../lib/nittymail/db"
require_relative "spec_helper"
require "sequel"

RSpec.describe NittyMail::DB do
  it "prunes missing uids from the email table" do
    db = Sequel.sqlite
    email = described_class.ensure_schema!(db)
    email.insert(address: "a@b", mailbox: "INBOX", uid: 1, uidvalidity: 10, message_id: "m1", date: nil, from: "[]", subject: "s", has_attachments: false, x_gm_labels: "", x_gm_msgid: "1", x_gm_thrid: "1", flags: "[]", encoded: "")
    email.insert(address: "a@b", mailbox: "INBOX", uid: 2, uidvalidity: 10, message_id: "m2", date: nil, from: "[]", subject: "s", has_attachments: false, x_gm_labels: "", x_gm_msgid: "2", x_gm_thrid: "2", flags: "[]", encoded: "")
    email.insert(address: "a@b", mailbox: "INBOX", uid: 3, uidvalidity: 10, message_id: "m3", date: nil, from: "[]", subject: "s", has_attachments: false, x_gm_labels: "", x_gm_msgid: "3", x_gm_thrid: "3", flags: "[]", encoded: "")

    count = described_class.prune_missing!(db, "INBOX", 10, [1, 3])
    expect(count).to eq(2)
    remain_uids = email.where(mailbox: "INBOX", uidvalidity: 10).select_map(:uid)
    expect(remain_uids).to eq([2])
  end
end
