# Technical Specification

This is the technical specification for the spec detailed in @.agent-os/specs/2025-09-05-sidekiq-mailbox-download/spec.md

## Technical Requirements

 - Add Redis + Active Job (Sidekiq adapter) to the CLI stack:
  - Gems: `activejob`, `redis`, `sidekiq` (and `sidekiq-redis` via `redis`), ensure compatibility with Ruby 3.4.
  - Docker Compose: add `redis` service; add a `worker` service that runs `bundle exec sidekiq -r ./sidekiq_boot.rb` with shared volumes (`job-data`).
  - Sidekiq config: `config/sidekiq.yml` with queues and concurrency; use 1 for `write` queue to serialize writes; allow N (e.g., 4–8) for `fetch` queue.
  - Active Job setup: configure `ActiveJob::Base.queue_adapter = :sidekiq` in `sidekiq_boot.rb` (and/or CLI init) and ensure Rails is not required (pure Ruby ActiveJob usage).

 - Job design (Active Job):
  - CLI enqueues `FetchJob` per UID batch with: `address`, `password` (app password), `mailbox`, `uidvalidity`, `uids`, `settings_args` (limited to non-secret if persisted), and `artifact_dir`.
  - `FetchJob` connects via `NittyMail::Mailbox` and writes each raw RFC822 to `artifact_dir/<address>/<mailbox>/<uidvalidity>/<uid>.eml`; after a batch completes, enqueue `WriteJob` per UID (or batched) containing file path + metadata.
  - `WriteJob` (queue `write`): reads file, parses via `mail` (subject/plain/markdown), normalizes UTF-8, and `upsert_all` to SQLite. After success, delete the artifact file.

- Serialization choices:
  - Avoid sending raw RFC822 in Redis payloads. Instead, pass small JSON payloads with file paths.
  - Use a shared bind-mounted `job-data` directory across CLI and worker services; subfolders by `address/mailbox/uidvalidity/`.
  - For safety, include a simple checksum in metadata (optional) to detect truncated files.

- CLI changes:
  - Flags: default is `--jobs` (job mode), `--no-jobs` forces single-process mode; job tuning flags: `--job-fetch-threads`, `--job-uid-batch-size`, `--job-write-batch-size` (optional).
  - Progress: initialize Redis keys: `jobs:total`, `jobs:processed`, `jobs:errors` per run-id; update progress bar by polling counters only (prefer Active Job–level APIs and avoid adapter-specific queue inspection).
  - Enqueue: preflight to get `uidvalidity` and list of UIDs; chunk by `--job-uid-batch-size` and enqueue FetchJob; set `jobs:total` to the total UID count.
  - Complete: poll until `processed + errors == total`. Prefer adapter-agnostic logic and do not depend on queue size inspection; jobs should be idempotent and increment counters upon completion.

- Graceful interrupts (jobs mode):
  - First SIGINT (Ctrl-C):
    - Stop enqueuing further jobs and stop progress polling loop.
    - Set a Redis flag `nm:dl:<run_id>:aborted=1`; jobs check this at start and self-terminate early without work.
    - Remove artifact files under `job-data/<address>/<mailbox>/<uidvalidity>/` that have not yet been processed (best-effort; match known `to_fetch` set).
    - Prefer Active Job–compatible approaches; use run-scoped abort semantics and avoid direct Sidekiq queue manipulation.
  - Second SIGINT: force exit immediately after best-effort cleanup attempt.
  - Implementation note: ensure jobs carry `run_id` in arguments so they can quickly exit when an abort flag is set and so artifact paths are namespaced.

 - Writer serialization:
  - Sidekiq concurrency for `write` queue set to 1; this provides single-writer semantics with SQLite.
  - Use AR connection established via the same helper; reuse `run_migrations!` on boot. Jobs should require `models/email` and `utils/db` in their boot file.

- Strict mode in jobs:
  - FetchJob: if `--strict`, re-raise IMAP/encoding errors so Sidekiq marks job as failed (retry setting configurable).
  - WriteJob: if `--strict`, re-raise on parse/upsert; otherwise skip and increment `jobs:errors`.

- Operational concerns:
  - Credentials are provided via env or Sidekiq job arguments and should not be logged.
  - Clean up artifact files even on partial failures (best-effort; consider retry locks to avoid double-writing).
  - Ensure idempotency: writer checks unique index on (`address`,`mailbox`,`uidvalidity`,`uid`).

## External Dependencies (Conditional)

- **redis**: in-memory data store for job queues and counters.
  - Justification: Sidekiq requires Redis; also used for progress counters.
- **sidekiq**: background job framework for Ruby.
  - Justification: robust job execution model with concurrency control.
