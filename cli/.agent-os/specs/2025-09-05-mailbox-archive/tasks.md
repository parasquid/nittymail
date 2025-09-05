# Spec Tasks

## Tasks

- [x] 1. CLI command and flags
  - [x] 1.1 Add `archive` subcommand to `cli mailbox`
  - [x] 1.2 Flags: `--mailbox`, `--output`, `--jobs` (optional), `--job_uid_batch_size`, `--strict`, `--max-fetch-size`
  - [x] 1.3 Default output folder to `cli/archives` and create `.keep`
  - [x] 1.4 Default execution is single‑process (no Redis); `--jobs` opt‑in

- [x] 2. Single-process archiver
  - [x] 2.1 Preflight; compute `to_archive` (server UIDs minus existing files)
  - [x] 2.2 Fetch in slices; atomic write `<uid>.eml`; skip existing
  - [x] 2.3 Progress bar and summary; strict vs skip-on-error handling

- [x] 3. Jobs mode (optional)
  - [x] 3.1 Implement `ArchiveFetchJob` (queue `fetch`)
  - [x] 3.2 Enqueue UID batches; initialize Redis counters `nm:arc:<run_id>:{total,processed,errors,aborted}`
  - [x] 3.3 Poll counters to update progress; completion when `processed+errors==total`
  - [x] 3.4 Prefer Active Job APIs in code/tests; no Sidekiq queue inspection

- [x] 4. Resumability and atomic writes
  - [x] 4.1 Skip if `<uid>.eml` exists; do not overwrite
  - [x] 4.2 Atomic write (`.tmp` → rename); ensure directories exist

- [ ] 5. Graceful interrupts
  - [x] 5.1 CLI: on first Ctrl‑C set abort flag and stop enqueues/polling; second Ctrl‑C force exit
  - [x] 5.2 Jobs: check abort flag on start and between messages and exit early
  - [x] 5.3 Cleanup: best-effort remove `.tmp` files; keep completed `.eml`

- [x] 6. Docs
  - [x] 6.1 README: usage, jobs default, output layout, progress, interrupts
  - [x] 6.2 AGENTS.md: test guidance (Active Job test adapter; Redis stubs)

- [ ] 7. Tests and quality
  - [x] 7.1 Smoke spec: archives sample UIDs; idempotency
  - [x] 7.2 Resumability spec: skip existing file(s)
  - [x] 7.3 Jobs integration spec: counters + files written
  - [x] 7.4 Strict-mode spec: fetch/write failure path (SystemExit)
  - [x] 7.5 Interrupts spec: single and double Ctrl‑C
  - [x] 7.6 Add gitignore rules for archives: ignore all under `archives/**` except `archives/.keep`
  - [ ] 7.7 Lint (StandardRB/RuboCop) and full RSpec run (green)
