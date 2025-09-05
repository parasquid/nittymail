# Spec Requirements Document

> Spec: sidekiq-mailbox-download
> Created: 2025-09-05

## Overview

Introduce a Redis-backed job-queue mode using Active Job with the Sidekiq adapter for `cli mailbox download` to parallelize IMAP fetching while keeping a single serialized writer for SQLite. Make job mode the default; retain single-process behavior behind `--no-jobs`. The CLI enqueues Active Job jobs, monitors queue progress via Redis, and updates the progress bar until completion.

## User Stories

### Faster Parallel Downloads

As a user, I want `mailbox download` to parallelize IMAP fetches so the overall download completes faster on large mailboxes, while writes to the SQLite DB remain consistent and safe.

Detailed workflow: The CLI enqueues UID batches to Active Job (Sidekiq adapter) on a `fetch` queue; multiple fetch jobs connect to IMAP in parallel and produce raw message artifacts into a shared job-data folder; a single writer job queue (`write` with concurrency 1 in Sidekiq) consumes small write jobs, parses, and writes rows to SQLite in batches.

### Keep Current Mode Available

As a user, I want to keep the current single-process mode so I can run without Redis/Sidekiq or for troubleshooting.

Detailed workflow: `mailbox download --no-jobs` forces the existing in-process flow; `mailbox download --jobs` uses the job-queue flow.

### Live Progress From Jobs

As a user, I want the CLI to show a progress bar and basic status while workers process jobs, so I can see total processed/remaining and ETA.

Detailed workflow: The CLI sets Redis counters for total enqueued and increments processed/error counters as the writer finishes; the CLI polls these counters and updates the progress bar until counters indicate completion and queues are empty.

## Spec Scope

1. **Job Mode Flagging**: Default to job mode (Active Job + Sidekiq). Add `--no-jobs` to force single-process mode. Add `--jobs` as an explicit opt-in alias for clarity.
2. **Compose Services**: Add a `redis` service and a `worker` service that runs Sidekiq (Active Job adapter); mount a shared `job-data` volume for message artifacts.
3. **Jobs**: Implement Active Job classes (using Sidekiq adapter):
   - FetchWorker (concurrent): connects to IMAP with given settings, fetches UID batches, writes raw RFC822 to files under `job-data/` (e.g., `<address>/<mailbox>/<uidvalidity>/<uid>.eml`), and enqueues a lightweight WriteJob with metadata + file path.
   - WriteWorker (serialized): Sidekiq `write` queue with concurrency 1 to parse files, derive subject/plain/markdown/etc., and upsert rows into SQLite; deletes artifact files after successful write.
4. **Serialization Strategy**: Avoid shipping raw RFC822 in Redis; pass only small JSON metadata and filesystem paths. The shared `job-data` folder is bind-mounted into both CLI and worker containers.
5. **Progress Reporting**: CLI initializes Redis counters (total, processed, errors), enqueues Active Job fetch jobs, and polls counters until done; renders progress bar similar to current behavior. Prefer Active Job–level APIs where possible rather than Sidekiq-specific queue inspection.
6. **Graceful Interrupts**: In jobs mode, first Ctrl-C triggers a graceful shutdown: stop polling/enqueuing, set an abort flag for the current run (e.g., `nm:dl:<run_id>:aborted=1` in Redis), and best‑effort remove any unprocessed artifact files for that run; second Ctrl-C forces an immediate exit. Jobs check the abort flag at start and self‑terminate without processing when set. Do not rely on Sidekiq-specific queue clearing; use run-scoped abort flags and idempotent job starts.
6. **Safety & Error Handling**: Respect `--strict` in job mode by failing jobs fast (retry strategy configurable); default skips and increments error counters. Ensure idempotent writes using the existing unique index.
7. **Config**: Flags for job-mode tuning: number of fetch workers, UID batch size for enqueues, and optional write batch size. Sensible defaults.
8. **Docs & Tests**: Update README and AGENTS for job mode; add smoke/integration specs with mocked IMAP that verify parallel fetching + single-writer semantics and progress polling. Prefer Active Job test helpers where possible; avoid Sidekiq-specific APIs in tests.

## Out of Scope

- Cross-host worker scaling or k8s deployment.
- Changing the SQLite schema; vector/embedding features remain out of scope.
- Complex job orchestration, dead-letter queues, or persistence beyond Redis/Sidekiq defaults.

## Expected Deliverable

1. Running `mailbox download --jobs` enqueues and processes fetch/write jobs to completion, with the CLI progress bar reflecting job counters.
2. Data is written correctly to SQLite via a single writer, with artifact files cleaned up. Single-process mode remains available via `--no-jobs`.
