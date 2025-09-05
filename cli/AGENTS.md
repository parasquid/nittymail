# Agent Guide (CLI)

This guide describes conventions and helpers for working in the `cli/` folder. The CLI now uses SQLite via ActiveRecord and the `nitty_mail` gem for IMAP — Chroma is no longer used.

## Style & Safety

- Prefer concise, descriptive names (e.g., `mailbox_client`, `fetch_response`).
- Use `until interrupted` rather than `loop do` for interrupt-aware loops.
- Rescue specific exceptions; log actionable context; avoid silent failure.
- When skipping or falling back, log class/message and identifiers (uidvalidity, uid, batch range).
- Do not hide initialization failures; fail fast with clear errors.
- Hash shorthand: `{foo:}` when key equals variable.

## Database (ActiveRecord + SQLite)

- Connection helper: `utils/db.rb`
  - `NittyMail::DB.establish_sqlite_connection(database_path:, address:)` sets pragmas (WAL, synchronous=NORMAL, temp_store=MEMORY).
  - Default DB path: `cli/data/[IMAP_ADDRESS].sqlite3` (override via `--database` or `NITTYMAIL_SQLITE_DB`).
  - `NittyMail::DB.run_migrations!` runs AR migrations.
- Model: `models/email.rb` defines validations and uses table `emails`.
- Git hygiene: `data/*.sqlite3` (and `-wal`/`-shm`) are gitignored; `data/.keep` ensures the directory exists.

## Downloader Behavior

- Command: `mailbox download`
- Core flow:
  - Preflight (via `nitty_mail`): get `uidvalidity` and `to_fetch` UIDs.
  - Diff: determine missing UIDs vs. DB (`address`, `mailbox`, `uidvalidity`, `uid`).
  - Fetch in slices; parse with `mail` and normalize to UTF-8.
  - Upsert rows with `upsert_all` keyed by the composite unique index.
- Progress: `ruby-progressbar` shows counts; Ctrl-C gracefully interrupts.
- Stored columns per email: raw (BLOB), plain_text, markdown, subject, internaldate, internaldate_epoch, rfc822_size, from_email, labels_json, to_emails, cc_emails, bcc_emails.

## Flags

- `--mailbox`: mailbox name (default `INBOX`).
- `--database`: override DB path.
- `--batch-size`: DB upsert chunk size (typical 100–500).
- `--max-fetch-size`: IMAP fetch slice size (typical 200–500; default from settings).
- `--strict`: fail-fast instead of skip-on-error (fetch/parse/upsert).
- `--recreate`: drop rows for current generation (address+mailbox+uidvalidity) and re-download (requires `--yes`/`--force` or prompt confirmation).
- `--purge-uidvalidity <n>`: delete rows for a specific generation and exit (requires `--yes`/`--force` or prompt confirmation).
- `--yes` / `--force`: auto-confirm destructive actions.

## Jobs Mode (Active Job + Sidekiq)

- Adapter: Active Job with the Sidekiq adapter. Prefer Active Job–level APIs when possible.
- Queues:
  - `fetch`: parallel workers fetch IMAP UIDs in batches, write `.eml` artifacts, and enqueue `WriteJob`.
  - `write`: single-concurrency worker parses artifacts and upserts to SQLite, then deletes artifacts.
- Artifacts: stored under `cli/job-data/<address>/<mailbox>/<uidvalidity>/<uid>.eml` with an SHA256 for integrity.
- Counters (Redis): `nm:dl:<run_id>:total|processed|errors` and `nm:dl:<run_id>:aborted`.
- CLI behavior:
  - Default uses jobs; `--no-jobs` forces single-process.
  - Polls counters to render progress; does not rely on adapter-specific queue inspection.
  - First Ctrl-C: sets abort flag, stops enqueues/polling, cleans artifacts. Second Ctrl-C: exits immediately.
- Tests:
  - Prefer Active Job’s `:test` adapter for unit/integration tests.
  - Stub Redis via a minimal in-memory object or mock; avoid Sidekiq-API-specific assertions.
  - Simulate interrupts by sending `INT` to the current process in specs.

## Archive Command

- Command: `mailbox archive` saves raw RFC822 `.eml` files named by UID; no parsing or DB writes.
- Output: `cli/archives/<address>/<sanitized-mailbox>/<uidvalidity>/<uid>.eml`.
  - `cli/archives/.keep` is tracked; all other files are gitignored.
- Resumability: skip existing files; atomic write (`.tmp` then rename).
- Jobs Mode: defaults to Active Job (Sidekiq adapter) when Redis reachable; `--no-jobs` for single‑process.
- Interrupts: first Ctrl‑C sets abort flag `nm:arc:<run_id>:aborted=1` and stops enqueues/polling; second Ctrl‑C forces exit; partial `.tmp` files are cleaned.
- Testing patterns: mirror jobs download approach (Active Job test adapter + Redis stubs); prefer adapter‑agnostic tests.

## Error Handling

- Default: skip-on-error with warnings (parse/encoding/fetch/upsert). Per-chunk upsert falls back to per-row.
- Strict: re-raise errors to abort the run; top-level handler exits with non-zero.

## Performance & Resumability

- Resumable: only missing UIDs are fetched; re-running processes new mail only.
- WAL enabled by default for better write throughput.
- Tuning:
  - Increase `--max-fetch-size` moderately if IMAP allows; watch server limits.
  - Reduce `--batch-size` if DB is the bottleneck; WAL generally absorbs bursts.

## Lint & Commit

- Run inside Docker from `cli/`:
  - `docker compose run --rm cli bundle install`
  - `docker compose run --rm cli bundle exec standardrb --fix`
  - `docker compose run --rm cli bundle exec rubocop -A`
  - `docker compose up -d redis worker_fetch worker_write` to run job workers locally
- Conventional Commits; use heredoc (`git commit -F - << 'EOF'`) to satisfy hooks.

## Tests

- Use rspec-given; see `spec/spec_helper.rb`.
- Run: `docker compose run --rm cli bundle exec rspec -fd -b`.
- Patterns:
  - Stub `NittyMail::Mailbox` for IMAP interactions.
  - Smoke specs for downloader (idempotency, parsed fields).
  - Resumability: pre-seed DB; ensure only missing UIDs are fetched.
  - Strict mode: expect fail-fast behavior (e.g., stub DB upsert failure).
  - Recreate/Purge: verify generation delete and safe confirmations.

## Adding Migrations & Flags

### Migrations

- Location: `db/migrate/` with incremental numeric prefixes (e.g., `002_add_email_indexes.rb`).
- Version: use `ActiveRecord::Migration[8.0]` to match the current AR version.
- Safety:
  - Prefer additive, reversible changes via `change`.
  - For destructive changes, provide explicit `up`/`down` and add tests.
  - Scope data operations carefully; use `where(...).delete_all` rather than unscoped deletes.
- Execution: `NittyMail::DB.run_migrations!` is invoked by the CLI before operations that need schema readiness.

### Adding CLI Flags

- Define with Thor `method_option` next to the command.
- Include clear descriptions, sensible defaults, and env var references when applicable.
- For destructive actions, require confirmation and support `--yes`/`--force`.
- Keep behaviors consistent with existing flags (e.g., `--strict` toggles fail-fast across fetch/parse/upsert).

### Tests for New Flags

- Use rspec-given; stub `NittyMail::Mailbox` for deterministic preflight/fetch.
- For maintenance flags, seed DB via `NittyMail::Email` and assert rows added/removed.
- For strict mode or failure scenarios, stub underlying calls (e.g., `Email.upsert_all`) to raise and assert non-zero exit via `SystemExit`.
