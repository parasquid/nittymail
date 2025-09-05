# Technical Specification

This is the technical specification for the spec detailed in @.agent-os/specs/2025-09-05-cli-db-mcp-server/spec.md

## Technical Requirements

- MCP Server over stdio
  - Protocol: JSON-RPC 2.0, MCP conventions (initialize, tools/list, tools/call, shutdown).
  - Transport: stdin/stdout streams; stderr for logs only.
  - Lifecycle:
    - Start: initialize → advertise capabilities (tools only).
    - Ready: respond to tools/list and tools/call.
    - Stop: handle explicit shutdown or EOF on stdin; graceful exit.
- Command surface
  - Thor: new command `db mcp` under existing CLI.
  - Options: `--database`, `--address`, `--max-limit` (cap, default 1000), `--quiet`.
  - Defaults & env vars:
    - `database`: default from `ENV["NITTYMAIL_SQLITE_DB"]` or `NittyMail::DB.default_database_path(address:)`.
    - `address`: default from `ENV["NITTYMAIL_IMAP_ADDRESS"]`.
    - `max_limit`: default 1000; allow `ENV["NITTYMAIL_MCP_MAX_LIMIT"]`.
    - `quiet`: default false; allow `ENV["NITTYMAIL_QUIET"]`.
    - Ensure `.env.sample` contains all envs used by this command (add missing keys with comments and sensible example values).
  - Uses existing ActiveRecord SQLite connection helper (`utils/db.rb`).
  - IMAP integration: MCP server has no IMAP connections. Use `nitty_mail` (path: `../gem`) only in non-MCP flows (e.g., downloader/sync).
  - File layout: implement command in `commands/db/mcp.rb` and wire into `cli.rb`.
  - Documentation: update CLI README and command `--help` to include usage, env defaults, and tool list with parameter/return shapes; note that semantic search is stubbed initially.
- Tools exposure and behavior (all read-only)
  - Field conventions
    - `date`: ISO8601 string or null (parsed from headers).
    - `internaldate`: ISO8601 string from IMAP INTERNALDATE.
    - `internaldate_epoch`: integer epoch seconds from IMAP INTERNALDATE; indexed and preferred for ordering/ranges.
    - `from`: sender display string (may include name and email).
    - `rfc822_size`: integer; bytesize of stored raw message (`encoded`).
    - `size_bytes`: integer; `LENGTH(encoded)` in SQLite when requested by tool.
  - Base list item fields
    - Unless otherwise noted, list-returning tools include: `{id, address, mailbox, uid, uidvalidity, message_id, x_gm_msgid, date, internaldate, internaldate_epoch, from, subject, rfc822_size}`.
  - Common:
    - All tool results are returned as MCP `tools/call` result content with a single item: `{type: "text", text: <json_string>}`.
    - Arguments validated and normalized (types, allowed enums, defaults, date parsing).
    - Limits enforced: clamp to `max_limit` and fallback defaults.
    - Ordering: deterministic where specified.
    - Errors: return MCP error with code + message; avoid leaking stack traces.
  - db.list_earliest_emails
    - Params: `limit` default 100; order by `date ASC NULLS LAST`, fallback `internaldate_epoch ASC`.
    - Returns: `[ {id, address, mailbox, uid, uidvalidity, message_id, x_gm_msgid, date, internaldate, internaldate_epoch, from, subject, rfc822_size} ]`.
  - db.get_email_full
    - Params: any of `id`, `mailbox`, `uid`, `uidvalidity`, `message_id`, `from_contains`, `subject_contains`, `date`, `order` (date_asc|date_desc).
    - Query resolution priority: `id` → (`mailbox`,`uid`,`uidvalidity`) → `message_id` → contains filters/date.
    - Returns single object with base fields (including identifiers `message_id`, `x_gm_thrid`, `x_gm_msgid`, and time fields `internaldate` and `internaldate_epoch`) + `encoded`, `envelope_to/cc/bcc/reply_to` (JSON arrays), `envelope_in_reply_to` (string|null), `envelope_references` (JSON array).
  - db.filter_emails
    - Params: `from_contains`, `from_domain` (accepts `@domain` or bare), `subject_contains`, `mailbox`, `date_from`, `date_to`, `order` (date_asc|date_desc), `limit`.
    - Returns: `[ {id, address, mailbox, uid, uidvalidity, message_id, x_gm_msgid, date, internaldate, internaldate_epoch, from, subject, rfc822_size} ]`; sanitize LIKE inputs (escape `%_`).
  - db.search_emails (stub)
    - Params: `query` (required), `item_types` (subject|body), `limit`.
    - Behavior: return predictable stub `{ id, address, mailbox, uid, uidvalidity, message_id, x_gm_msgid, date, internaldate, internaldate_epoch, from, subject, score }[]`, ordered by `score ASC`. Initially returns an empty list and logs `"semantic search not yet implemented"` to stderr; do not error.
  - db.count_emails
    - Same filters as `db.filter_emails`; returns `{count}`.
  - db.get_email_stats
    - Params: `top_limit` default 10.
    - Returns: `{ total_emails, date_range: {earliest, latest}, top_senders: [{from, count}], top_domains: [{domain, count}], mailbox_distribution: [{mailbox, count}] }`.
  - db.get_top_senders
    - Params: `limit` default 20, `mailbox` optional.
    - Returns: `[{from, count}]`.
  - db.get_top_domains
    - Params: `limit` default 20.
    - Returns: `[{domain, count}]` (extract domain from `from_email` if available; else parse from `from`).
  - db.get_largest_emails
    - Params: `limit` default 5, `attachments` (any|with|without), `mailbox`, `from_domain`.
    - Returns: list `[ {id, address, mailbox, uid, uidvalidity, message_id, x_gm_msgid, date, internaldate, internaldate_epoch, from, subject, rfc822_size, size_bytes} ]` with `size_bytes = length(encoded)`; order by `size_bytes DESC`.
  - db.get_mailbox_stats
    - Params: none; returns `[{mailbox, count}]`.
  - db.get_emails_by_date_range
    - Params: `period` (daily|monthly|yearly, default monthly), `date_from`, `date_to`, `limit` default 50.
    - Returns: `[{period, count}]` with `period` formatted: `YYYY-MM-DD`, `YYYY-MM`, or `YYYY`.
  - db.get_emails_with_attachments
    - Params: `mailbox`, `date_from`, `date_to`, `limit` default 100; filter `has_attachments = true`.
    - Returns: base list shape `{id, address, mailbox, uid, uidvalidity, message_id, x_gm_msgid, date, internaldate, internaldate_epoch, from, subject, rfc822_size}`.
  - db.get_email_thread
    - Params: `thread_id` (x_gm_thrid), `order` (date_asc default, date_desc allowed).
    - Returns: base list shape `{id, address, mailbox, uid, uidvalidity, message_id, x_gm_msgid, date, internaldate, internaldate_epoch, from, subject, rfc822_size}`.
  - db.get_email_activity_heatmap
    - Params: `date_from`, `date_to`; Returns: `[{hour, day_of_week, day_number, count}]` with day names Sun–Sat and 0–6 mapping.
  - db.get_response_time_stats
    - Params: `limit` default 50; compute inter-email deltas within thread; ordered by response time desc.
  - db.get_email_frequency_by_sender
    - Params: `sender` contains match, `period` (daily|monthly|yearly), `limit`.
  - db.get_seasonal_trends
    - Params: `years_back` default 3; output `{year, month, count, season, month_name}`; derive season from month.
  - db.get_emails_by_size_range
    - Params: `size_category` (small<10KB, medium 10–100KB, large>100KB, huge>1MB), `limit`.
    - Returns: `[ {id, address, mailbox, uid, uidvalidity, message_id, x_gm_msgid, date, internaldate, internaldate_epoch, from, subject, size_bytes} ]`.
  - db.get_duplicate_emails
    - Params: `similarity_field` (subject|message_id, default subject), `limit`.
    - Returns: `[{similarity_field, duplicate_count, email_ids}]` where `email_ids` is array of IDs per duplicate group.
  - db.search_email_headers
    - Params: `header_pattern`, `limit`; apply validated REGEXP/LIKE on `encoded` with size guard; may fallback to LIKE if REGEXP unsupported.
    - Returns: `[ {id, address, mailbox, uid, uidvalidity, message_id, x_gm_msgid, date, internaldate, internaldate_epoch, from, subject} ]`.
  - db.get_emails_by_keywords
    - Params: `keywords` (array, required), `match_mode` (any|all), `limit`; compute `keyword_match_count` and `keyword_match_score` from occurrences in subject/plain_text.
    - Returns: `[ {id, address, mailbox, uid, uidvalidity, message_id, x_gm_msgid, date, internaldate, internaldate_epoch, from, subject, keyword_match_count, keyword_match_score} ]` ordered by match score.
  - db.execute_sql_query (secure read-only)
    - Params: `sql_query` (required), `limit` default 1000.
    - Validation: allow only SELECT or WITH; reject INSERT/UPDATE/DELETE/CREATE/ALTER/DROP/TRUNCATE/PRAGMA/BEGIN/COMMIT/ROLLBACK; single statement only.
    - Safety: auto-append `LIMIT` if missing; cap to `max_limit`; timeout via statement interruption if supported; reject overly long queries.
    - Returns: `{query, row_count, rows}` where `rows` is array of objects (column name → value).

- Data model and queries
  - Use existing ActiveRecord models (e.g., `Email`) with the `emails` table and known columns: id, address, mailbox, uid, uidvalidity, message_id, x_gm_thrid, x_gm_msgid, date, internaldate, internaldate_epoch, rfc822_size, raw, plain_text, subject, from_email, from, labels_json, has_attachments, envelope_reply_to, envelope_in_reply_to, envelope_references.
  - Prefer AR query methods; for aggregation or SQLite built-ins, use `connection.select_all` with parameter binding.
  - For `size_bytes`, use `LENGTH(encoded)` projection.

- Performance
  - Ensure indexes are used where available (mailbox, uid, uidvalidity, message_id, date).
  - Clamp limits and avoid SELECT * on large payloads unless requested (e.g., `get_email_full`).
  - Stream results into arrays; avoid loading huge result sets; enforce `max_limit`.

- Error handling and logging
  - Validate params with helpful error messages; return MCP error responses for invalid input.
  - Log to stderr: server start/stop, tool calls (name, duration), and warnings (no PII/large payloads).
  - No silent failures; strict mode is not required but reject invalid operations clearly.

- Testing
  - Add RSpec examples (CLI-level) using Active Job test adapter only if needed for helpers; otherwise pure unit.
  - Simulate MCP interactions by sending JSON-RPC messages to the command’s stdin and reading stdout.
  - Cover: tools/list response shape, representative tools (filters, stats), SQL safety checks, and stubbed search.

## External Dependencies (Conditional)

No new runtime dependencies required. Use existing Ruby stdlib (JSON, IO), Thor, ActiveRecord/SQLite, and the local `nitty_mail` gem (path: `../gem`). If a minimal JSON-RPC helper is desired, implement inline utility methods rather than adding a gem. If gaps are identified in `nitty_mail`, propose them for owner review before extending the gem.
