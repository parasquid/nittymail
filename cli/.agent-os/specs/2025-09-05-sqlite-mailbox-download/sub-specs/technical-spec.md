# Technical Specification

This is the technical specification for the spec detailed in @.agent-os/specs/2025-09-05-sqlite-mailbox-download/spec.md

## Technical Requirements

- Runtime & Language: Ruby 3.4; executed via the existing CLI Docker setup.
- Persistence: ActiveRecord with `sqlite3` adapter writing to a single DB file (e.g., `cli/nittymail.sqlite3` by default, overridable via flag or env).
- ORM Setup:
  - Add gems: `activerecord`, `sqlite3`, `activesupport` (for time zone/inflector helpers if needed).
  - Create a small database helper to initialize ActiveRecord connection, enable WAL, and set pragmas.
  - Provide a migration runner (standalone ActiveRecord migrations) with a first migration creating `emails` table and indexes.
- Schema (table: `emails`):
  - address (string, not null)
  - mailbox (string, not null)
  - uidvalidity (integer, not null)
  - uid (integer, not null)
  - subject (text)
  - internaldate (datetime, not null)
  - internaldate_epoch (integer, not null)
  - rfc822_size (integer)
  - from_email (string)
  - to_emails (text)         # serialized list (comma-delimited) or JSON string
  - cc_emails (text)         # serialized list (comma-delimited) or JSON string
  - bcc_emails (text)        # serialized list (comma-delimited) or JSON string
  - labels_json (text)       # serialized JSON array from IMAP labels
  - raw (binary / blob, not null)
  - plain_text (text)
  - markdown (text)
  - created_at (datetime)
  - updated_at (datetime)
  - Indexes:
    - unique index on (address, mailbox, uidvalidity, uid)
    - index on internaldate_epoch
    - optional index on subject
- IMAP Download Flow:
  - Preflight per mailbox: get `UIDVALIDITY`, list server UIDs, diff with DB by composite key.
  - Fetch in batches (e.g., 200–500 UIDs per batch), with N parallel fetchers (2–4), and a single writer thread or a bounded writer pool that serializes DB commits via a queue.
  - Store raw RFC822 exactly as received; parse with `mail` gem to extract subject and generate `plain_text` and `markdown` views.
  - Use transactions for batch inserts; commit every N records (e.g., 200) to balance durability and throughput.
  - Enable `journal_mode=WAL`, `synchronous=NORMAL`, `temp_store=MEMORY`, and prepared statements where practical.
- CLI Command Changes (`cli mailbox download`):
  - Remove Chroma/embedding-related flags and code paths.
  - Keep essentials: `--address`, `--password`, `--only`, `--ignore`, `--threads`, `--batch-size`, `--database`.
  - Update help text and docs to reflect SQLite/ActiveRecord backend.
- Parsing Rules:
  - `subject`: from parsed headers; fall back to empty string if missing.
  - `internaldate`: from IMAP `INTERNALDATE`; also store `internaldate_epoch` for indexing.
  - `plain_text`: prefer text/plain parts; if only HTML exists, convert to text (basic HTML-to-text sanitization).
  - `markdown`: lightweight conversion: headers from subject, basic lists/links from HTML if present; keep deterministic and simple.
  - `from_email`, `to_emails`, `cc_emails`, `bcc_emails`: normalized to lower-case addresses; join lists with commas or store as JSON string.
  - `labels_json`: JSON-encoded labels array when available.
- Idempotency & Resume:
  - Before insert, probe by composite key; skip if found.
  - If `uidvalidity` changes for a mailbox, prior rows remain; unique key naturally isolates generations; optional future purge out of scope.
- Error Handling:
  - Retry IMAP batches up to configured attempts with backoff for transient errors.
  - Log failures with mailbox, uidvalidity, uid, and range context; continue batch processing where safe.
  - Fail fast on DB initialization errors with clear messaging.
- Progress & Signals:
  - Emit progress events (e.g., batches enqueued, batch fetch start/finish, rows written) to existing reporter.
  - First Ctrl-C requests graceful stop; second Ctrl-C forces abort after finalizing in-flight transaction.
- Performance Criteria:
  - With WAL and batched transactions, sustain significantly higher write throughput than prior Chroma path on the same dataset (qualitative acceptance: noticeably faster end-to-end for small/medium mailboxes; quantitative tuning can follow).

## External Dependencies (Conditional)

- activerecord: ORM for SQLite integration.
  - Justification: Provides migrations, schema management, and a stable Ruby ORM.
- sqlite3: SQLite driver.
  - Justification: Direct, embedded storage replacing networked Chroma.
- activesupport (if needed): Time and utility helpers.
  - Justification: Convenience methods frequently used alongside ActiveRecord.

## Implementation Tasks

- Update dependencies:
  - Add `activerecord`, `sqlite3`, and (optionally) `activesupport` to `Gemfile`; run bundle install in Docker.
- Initialize ORM:
  - Create `utils/db.rb` (or similar) to establish ActiveRecord connection to the configured SQLite file and set PRAGMAs (WAL, synchronous=NORMAL, temp_store=MEMORY).
  - Add a lightweight migration runner (e.g., `db/migrate/001_create_emails.rb`) and an entrypoint to run migrations at startup.
- Define schema:
  - Implement `CreateEmails` migration as specified; ensure composite unique index and `internaldate_epoch` index.
- Refactor downloader:
  - Remove Chroma-related code paths, flags, and helpers from `cli mailbox download`.
  - Implement write pipeline that validates uniqueness by (address, mailbox, uidvalidity, uid) before insert.
  - Batch inserts in transactions with a bounded queue between fetchers and writer(s).
- Parsing utilities:
  - Build helpers that accept raw RFC822 and produce: subject, from/to/cc/bcc, plain text (HTML fallback), and simple markdown.
- Performance & reliability:
  - Configure IMAP fetch batch size and threads; add retry with backoff; safe shutdown on SIGINT.
- Reporting & UX:
  - Emit progress events for batches fetched/written; update CLI help text to show SQLite-focused options.
- Tests:
  - Unit: parser (text and markdown derivation), schema uniqueness and indexes, idempotent writes.
  - Integration (lightweight): mock IMAP fetch returning a few RFC822 samples and verify rows written and resumability.
- Documentation:
  - Update README/help to remove Chroma references and document the new schema and flags.
