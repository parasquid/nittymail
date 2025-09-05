# Spec Requirements Document

> Spec: mailbox-archive
> Created: 2025-09-05

## Overview

Introduce a new `cli mailbox archive` command that downloads all messages from a mailbox into raw RFC822 files, naming them by UID. No parsing or database writes are performed. The command is resumable (skips already-archived UIDs), displays a progress bar, and uses a jobs mode (Active Job + Sidekiq adapter) by default with `--no-jobs` to run without Redis. Archives include a `.keep` file so the folder is tracked, and all other archived files are gitignored to avoid accidental commits.

## User Stories

1) Archive Raw Mail
- As a user, I want to archive all messages from a mailbox into `.eml` files named by UID, so I can store and process them later without the CLI modifying or parsing content.

2) Resumable & Idempotent
- As a user, I want to safely re-run archiving and only fetch missing UIDs, so repeated runs are fast and safe.

3) Jobs Mode by Default
- As a user, I want parallelized fetches by default (Active Job + Sidekiq adapter) with a `--no-jobs` opt-out that runs without Redis for portability.

4) Progress & Summary
- As a user, I want a progress bar and a final summary with counts for processed and errors.

5) Graceful Interrupts
- As a user, I want Ctrl‑C to stop enqueues and polling gracefully and let jobs stop themselves quickly, with a second Ctrl‑C forcing exit.

## Scope

1. CLI Command: `mailbox archive`
- Flags:
  - `--mailbox` (default `INBOX`)
  - `--output` base directory (default `cli/archives`)
  - `--no-jobs` to force single‑process mode
  - `--job_uid_batch_size` (default 200)
  - `--strict` fail-fast instead of skip-on-error
  - `--max-fetch-size` override IMAP fetch slice size
- Output layout: `cli/archives/<address>/<sanitized-mailbox>/<uidvalidity>/<uid>.eml`; ensure a `.keep` exists under `cli/archives/` so the directory is tracked.
- Resumability: skip if `<uid>.eml` exists.

2. Jobs Mode (default)
- Active Job (Sidekiq adapter) with a new `ArchiveFetchJob` on the `fetch` queue:
  - Fetches UIDs in batches and writes `.eml` files atomically (`.tmp` → rename).
  - Increments Redis counters per saved UID (`processed`) and per error (`errors`).
  - No writer job is needed (raw files only).
- Redis counters: `nm:arc:<run_id>:{total,processed,errors,aborted}`.
- CLI behavior:
  - Enqueue `ArchiveFetchJob` per UID batch.
  - Poll Redis counters to update the progress bar; completion at `processed + errors == total`.
  - On first Ctrl‑C: set abort flag and stop enqueues/polling; jobs check flag and self-terminate. Second Ctrl‑C: force exit.
- Prefer Active Job–level APIs in code and tests; avoid Sidekiq-specific queue inspection.

3. Single‑Process Mode (`--no-jobs`)
- Similar to the current download flow but without parsing/DB writes:
  - Fetch in slices, write `.eml` files (atomic writes), track progress.
  - Skip existing files for resumability.

4. Error Handling
- Default: skip-on-error with warnings (fetch/write), continue archiving remaining UIDs.
- `--strict`: re-raise errors and exit with non-zero.

5. Progress & Summary
- Progress bar shows processed out of total.
- Final summary prints `processed` and `errors` counts.

6. Documentation & Tests
- README: add archive command usage, jobs mode behavior, progress, resumability, interrupts, and note that archives are gitignored except for `.keep`.
- AGENTS.md: add archive testing patterns (Active Job test adapter), conventions.
- Specs: smoke/integration tests for both jobs and no-jobs; strict mode; resumability; interrupts.

## Out of Scope
- Parsing, metadata extraction, or database writes.
- Compression, encryption, or upload to remote storage.
- Cross-host artifact coordination beyond the shared local folder.

## Deliverable
1. `mailbox archive` command that produces `.eml` files named by UID, with progress bar, resumability, jobs mode default, and single-process fallback.
2. Working specs and updated docs.
