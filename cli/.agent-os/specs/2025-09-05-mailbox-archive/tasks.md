# Spec Tasks

## Tasks

- [ ] 1. CLI command and flags
  - [ ] 1.1 Add `archive` subcommand to `cli mailbox`
  - [ ] 1.2 Flags: `--mailbox`, `--output`, `--no-jobs`, `--job_uid_batch_size`, `--strict`, `--max-fetch-size`
  - [ ] 1.3 Default output folder to `cli/archives` and create `.keep`

- [ ] 2. Single-process archiver
  - [ ] 2.1 Preflight; compute `to_archive` (server UIDs minus existing files)
  - [ ] 2.2 Fetch in slices; atomic write `<uid>.eml`; skip existing
  - [ ] 2.3 Progress bar and summary; strict vs skip-on-error handling

- [ ] 3. Jobs mode (default)
  - [ ] 3.1 Implement `ArchiveFetchJob` (queue `fetch`)
  - [ ] 3.2 Enqueue UID batches; initialize Redis counters `nm:arc:<run_id>:{total,processed,errors,aborted}`
  - [ ] 3.3 Poll counters to update progress; completion when `processed+errors==total`
  - [ ] 3.4 Prefer Active Job APIs in code/tests; no Sidekiq queue inspection

- [ ] 4. Resumability and atomic writes
  - [ ] 4.1 Skip if `<uid>.eml` exists; do not overwrite
  - [ ] 4.2 Atomic write (`.tmp` → rename); ensure directories exist

- [ ] 5. Graceful interrupts
  - [ ] 5.1 CLI: on first Ctrl‑C set abort flag and stop enqueues/polling; second Ctrl‑C force exit
  - [ ] 5.2 Jobs: check abort flag on start and between messages and exit early
  - [ ] 5.3 Cleanup: best-effort remove `.tmp` files; keep completed `.eml`

- [ ] 6. Docs
  - [ ] 6.1 README: usage, jobs default, output layout, progress, interrupts
  - [ ] 6.2 AGENTS.md: test guidance (Active Job test adapter; Redis stubs)

- [ ] 7. Tests and quality
  - [ ] 7.1 Smoke spec: archives sample UIDs; idempotency
  - [ ] 7.2 Resumability spec: skip existing file(s)
  - [ ] 7.3 Jobs integration spec: counters + files written
  - [ ] 7.4 Strict-mode spec: fetch/write failure path (SystemExit)
  - [ ] 7.5 Interrupts spec: single and double Ctrl‑C
  - [ ] 7.6 Add gitignore rules for archives: ignore all under `archives/**` except `archives/.keep`
  - [ ] 7.7 Lint (StandardRB/RuboCop) and full RSpec run (green)
