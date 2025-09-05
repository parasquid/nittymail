# Technical Specification

This is the technical specification for the spec detailed in @.agent-os/specs/2025-09-05-mailbox-archive/spec.md

## CLI Command

- Add Thor subcommand: `cli mailbox archive`.
- Flags:
  - `--mailbox` (String, default `INBOX`)
  - `--output` (String, default `cli/archives`)
  - `--no-jobs` (Boolean): force single-process mode
  - `--job_uid_batch_size` (Integer, default 200)
  - `--max-fetch-size` (Integer, optional override for settings)
  - `--strict` (Boolean): fail-fast on errors
- Path building:
  - Base dir: `options[:output] || ENV['NITTYMAIL_ARCHIVE_DIR'] || File.expand_path('archives', __dir__)`
  - Tree: `<base>/<address>/<sanitized-mailbox>/<uidvalidity>/<uid>.eml`
  - Use existing `NittyMail::Utils.sanitize_collection_name` for mailbox; downcase address.
- Preflight via `NittyMail::Mailbox#preflight` to get `uidvalidity` and `to_fetch`.
- Determine `to_archive` = server UIDs minus existing files in the target folder.

## Jobs Mode (default)

- Adapter: Active Job with the Sidekiq adapter (existing setup). Prefer Active Job–level APIs where possible.
- New job: `ArchiveFetchJob` (queue: `fetch`).
  - Args: `address`, `password`, `mailbox`, `uidvalidity`, `uids`, `settings`, `artifact_dir`, `run_id`, `strict`.
  - Behavior:
    - Respect abort flag at start and between messages: read `nm:arc:<run_id>:aborted` from Redis.
    - For each message in `uids`:
      - Fetch via `NittyMail::Mailbox#fetch`.
      - Write raw body to `<uid>.eml` via atomic write: write to `.<uid>.eml.tmp` then `rename`.
      - Increment `processed` counter.
      - On error: warn; if `strict` then re-raise; else increment `errors`.
    - Close/disconnect mailbox client in ensure.
- Redis counters:
  - `nm:arc:<run_id>:total` = total UIDs to archive
  - `nm:arc:<run_id>:processed` incremented per saved file
  - `nm:arc:<run_id>:errors` incremented per error
  - `nm:arc:<run_id>:aborted` set to `1` when aborting
- CLI orchestration:
  - Initialize counters (total/processed/errors/aborted=0).
  - Enqueue `ArchiveFetchJob` for each UID slice of `--job_uid_batch_size`.
  - Poll counters to update progress bar until `processed + errors == total` or aborted.
  - Interrupts: first Ctrl‑C sets abort flag and stops enqueues/polling; second Ctrl‑C exits immediately. Best-effort sweeping of `.tmp` files; already written `.eml` files remain as partial progress.

## Single-Process Mode (`--no-jobs`)

- Loop through `to_archive` in slices of `settings.max_fetch_size`.
- For each fetched message:
  - Atomic write to `<uid>.eml`.
  - Update progress bar.
  - On error: warn; if `strict` then raise; else continue.

## Resumability

- Skip any UID whose `<uid>.eml` already exists.
- Treat existing files as successfully archived; do not overwrite.

## Error Handling

- Strict mode: re-raise on fetch or write error; top-level handler exits with non-zero.
- Default: skip-on-error and continue; log `uidvalidity`, `uid`, and batch context.

## Paths & Git Ignore

- Default base output directory: `cli/archives`.
- Ensure a `.keep` file exists at `cli/archives/.keep` so the folder is tracked.
- Add `.gitignore` rules to ignore archived content while keeping `.keep`:
  - `archives/**`
  - `!archives/.keep`

## Tests

- Smoke test: archives two UIDs; verifies files exist and are raw content; idempotent on re-run.
- Resumability: pre-create one UID file and verify only new UIDs are written.
- Jobs mode integration (Active Job test adapter): enqueue `ArchiveFetchJob` batches; verify counters and file outputs.
- Strict mode: force errors (fetch/write) and assert CLI exits non-zero (SystemExit).
- Interrupts: simulate single and double Ctrl‑C; assert abort flag set; verify in-progress loop stops and partial files remain; `.tmp` files cleaned.

## Documentation

- README: add usage examples for `mailbox archive`, jobs mode, defaults, output layout, and interrupts.
- AGENTS.md: add testing patterns for archive, emphasizing Active Job test adapter and Redis stubs.
