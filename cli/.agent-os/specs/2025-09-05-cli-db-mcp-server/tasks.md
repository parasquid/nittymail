# Spec Tasks

## Tasks

- [ ] 1. Database schema and model wiring
  - [x] 1.1 Write tests for migration creating `emails` with all required columns and indexes
  - [x] 1.2 Ensure migration defines: address, mailbox, uidvalidity, uid, message_id, x_gm_thrid (int64), x_gm_msgid (int64), subject, internaldate, internaldate_epoch, rfc822_size, from, from_email, to_emails, cc_emails, bcc_emails, envelope_reply_to, envelope_in_reply_to, envelope_references, date, has_attachments, labels_json, raw, plain_text, markdown, timestamps
  - [x] 1.3 Ensure indexes: composite identity, internaldate_epoch, subject, message_id, x_gm_thrid, x_gm_msgid, from_email, date
  - [x] 1.4 Validate ActiveRecord model maps fields and validations (presence for core identity + internaldate/internaldate_epoch/raw)
  - [ ] 1.5 Verify all tests pass

- [ ] 2. Downloader/parser enrichment (populate new columns via nitty_mail)
  - [ ] 2.1 Write tests for parsing and populating: message_id, x_gm_thrid, x_gm_msgid, date (header), internaldate/internaldate_epoch, from/from_email, to/cc/bcc, envelope_reply_to, envelope_in_reply_to, envelope_references, has_attachments, rfc822_size, plain_text, markdown
  - [ ] 2.2 Capture Gmail IMAP attributes (X-GM-THRID, X-GM-MSGID) during FETCH via `nitty_mail` and persist
  - [ ] 2.3 Parse MIME to compute `has_attachments` and `rfc822_size` (bytes)
  - [ ] 2.4 Normalize addresses and serialize arrays as JSON where applicable
  - [ ] 2.5 Compute `internaldate_epoch` and ensure dual time fields are stored
  - [ ] 2.6 Upsert rows keyed by (address, mailbox, uidvalidity, uid); idempotent on re-run
  - [ ] 2.7 Verify all tests pass

- [ ] 3. MCP server scaffolding (stdio)
  - [ ] 3.1 Write tests simulating MCP initialize, tools/list, tools/call over stdio
  - [ ] 3.2 Implement Thor command `db mcp` in `commands/db/mcp.rb` with `--database`, `--address`, `--max-limit`, `--quiet`, and register it in `cli.rb`
  - [ ] 3.2.1 Honor env defaults: `NITTYMAIL_SQLITE_DB`, `NITTYMAIL_IMAP_ADDRESS`, optional `NITTYMAIL_MCP_MAX_LIMIT`, `NITTYMAIL_QUIET`
  - [ ] 3.3 Implement JSON-RPC/MCP loop: initialize, list tools, dispatch tools/call, shutdown/EOF handling
  - [ ] 3.4 Add minimal stderr logging (start/stop, tool durations), no sensitive payloads
  - [ ] 3.5 Verify all tests pass

- [ ] 4. Implement MCP tools (queries + safety)
  - [ ] 4.1 Write tests for representative tools: `db.filter_emails`, `db.get_top_senders`, `db.get_largest_emails`, `db.get_mailbox_stats`, `db.execute_sql_query`
  - [ ] 4.2 Implement all endpoints with parameter validation and defaults; clamp limits; sanitize LIKE patterns
  - [ ] 4.3 Ensure list-returning tools include: `{id, address, mailbox, uid, uidvalidity, message_id, x_gm_msgid, date, internaldate, internaldate_epoch, from, subject, rfc822_size}` (plus tool-specific fields)
  - [ ] 4.4 Use `internaldate_epoch` for ordering/range filters; include `internaldate` as ISO8601 in output
  - [ ] 4.5 Implement `db.execute_sql_query` with read-only validation (SELECT/WITH only) and auto-LIMIT
  - [ ] 4.6 Stub `db.search_emails` returning empty list with correct shape and info log
  - [ ] 4.7 Verify all tests pass

- [ ] 5. Documentation and validation
  - [ ] 5.1 Update CLI README and command help for `db mcp` usage, options, defaults via env vars
  - [ ] 5.2 Document tool list with params and return shapes; include note that `db.search_emails` is stubbed
  - [ ] 5.2.1 Update `.env.sample` to include any missing env vars used by this command (e.g., `NITTYMAIL_SQLITE_DB`, `NITTYMAIL_MCP_MAX_LIMIT`, `NITTYMAIL_QUIET`) with comments and example values
  - [ ] 5.3 Run `./bin/lint` and RSpec via Docker; ensure green
  - [ ] 5.4 Smoke test with a local MCP client (manual) to confirm stdio behavior
