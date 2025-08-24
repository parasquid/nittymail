# Gmail IMAP Extensions: X-GM-LABELS, X-GM-MSGID, X-GM-THRID

Gmail exposes additional IMAP attributes that enrich message metadata beyond standard IMAP. NittyMail reads these via UID FETCH and stores them in the SQLite table columns `x_gm_labels`, `x_gm_msgid`, and `x_gm_thrid`.

## X-GM-LABELS
- Meaning: The set of Gmail labels applied to a message (similar to tags, not folders). Includes system labels (e.g., "\\\Important", "\\\Starred").
- Type: IMAP list of strings; label names may include spaces and need quoting.
- Use: Filter or group messages by labels without relying on folder placement.
- Example IMAP: `UID FETCH 12345 (X-GM-LABELS)` → `("\\\Starred" "Work/Clients" "Project Alpha")`

## X-GM-MSGID
- Meaning: A 64-bit immutable identifier for the logical message across the entire account.
- Type: Integer-like string; stable across folders/labels and copies.
- Use: Deduplicate messages that appear in multiple labels/folders; correlate across syncs.
- Example IMAP: `UID FETCH 12345 (X-GM-MSGID)` → `1737456873291045678`

## X-GM-THRID
- Meaning: A 64-bit identifier for the Gmail conversation (thread) the message belongs to.
- Type: Integer-like string shared by all messages in the same conversation.
- Use: Group messages into threads without parsing headers.
- Example IMAP: `UID FETCH 12345 (X-GM-THRID)` → `1737456873291045600`

## In This Repository
- Retrieval: See `core/sync.rb` (calls `imap.uid_fetch(uid, ["X-GM-LABELS"])`, etc.).
- Storage: Persisted in SQLite as text columns; useful for fast thread or label queries.
- Example query: `SELECT COUNT(*) FROM email WHERE x_gm_thrid = '<thread_id>';`

## Notes
- Do not confuse `X-GM-MSGID` with RFC 5322 `Message-ID` (header). They serve different purposes.
- Standard IMAP servers do not provide these attributes; they are Gmail-specific.
- Threads are Gmail’s conversation model and may not match `References`/`In-Reply-To` graphs exactly.
