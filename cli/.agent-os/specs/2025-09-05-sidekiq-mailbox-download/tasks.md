# Spec Tasks

## Tasks

- [x] 1. Add Redis + Active Job (Sidekiq adapter) and boot
  - [x] 1.1 Add gems (`activejob`, `redis`, `sidekiq`) and bundle install
  - [x] 1.2 Add `config/sidekiq.yml` and `sidekiq_boot.rb` wiring AR + migrations; set `ActiveJob::Base.queue_adapter = :sidekiq`
  - [x] 1.3 Add Docker Compose `redis` service and `worker` service with shared volumes
  - [x] 1.4 Verify services start and Sidekiq connects to Redis

- [x] 2. Implement jobs and artifact pipeline
  - [x] 2.1 Create `job-data/` shared folder and ensure `.keep`
  - [x] 2.2 Implement `FetchJob` (IMAP batch fetch → write `.eml` files → enqueue `WriteJob`)
  - [x] 2.3 Implement `WriteJob` (queue `write`, concurrency 1) to parse + upsert + cleanup
  - [x] 2.4 Ensure idempotency and error handling (`--strict` aware)

- [x] 3. CLI integration (default `--jobs`) and progress
  - [x] 3.1 Add flags: default `--jobs`, `--no-jobs` to force single-process, and job tuning flags
  - [x] 3.2 Enqueue UID batches and initialize Redis counters (total/processed/errors)
- [x] 3.3 Poll counters and update progress bar until completion (prefer Active Job APIs when possible)
  - [x] 3.4 Fallback to existing single-process flow when `--no-jobs` is set (or Redis unavailable)

- [x] 4. Serialization and safety
  - [x] 4.1 Store only file paths and small JSON payloads in Redis
  - [x] 4.2 Organize artifacts by `address/mailbox/uidvalidity/uid.eml`
  - [x] 4.3 Best-effort cleanup and optional checksum validation (added SHA256 to jobs and validated in writer)

- [ ] 5. Graceful interrupts (jobs mode)
  - [x] 5.1 Ensure jobs carry `run_id` to support selective cleanup
  - [x] 5.2 On first Ctrl-C: stop enqueuing/polling, set abort flag in Redis for `run_id` (e.g., `nm:dl:<run_id>:aborted=1`), have jobs check this and self-terminate early; best-effort delete unprocessed artifacts (no Sidekiq queue manipulation)
  - [x] 5.3 On second Ctrl-C: force quit after best-effort cleanup
  - [x] 5.4 Add specs for graceful vs forceful interrupts (prefer Active Job test helpers and stubbing Redis/filesystem; avoid Sidekiq-specific APIs)

- [ ] 6. Docs and examples
  - [ ] 6.1 Update README (job-mode quickstart, flags, compose services, interrupts)
  - [ ] 6.2 Update AGENTS.md (job-mode guidance, testing patterns, interrupts)

- [ ] 7. Tests and quality
  - [x] 7.1 Add integration specs: enqueue + parallel fetch + single writer writes
  - [x] 7.2 Add strict-mode spec for job failures (fetch/write)
  - [x] 7.3 Lint (StandardRB/RuboCop) and full RSpec run (green)
