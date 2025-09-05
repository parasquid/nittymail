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

- [ ] 3. CLI integration (default `--jobs`) and progress
  - [ ] 3.1 Add flags: default `--jobs`, `--no-jobs` to force single-process, and job tuning flags
  - [ ] 3.2 Enqueue UID batches and initialize Redis counters (total/processed/errors)
  - [ ] 3.3 Poll counters and queue sizes; update progress bar until completion
  - [ ] 3.4 Fallback to existing single-process flow when `--no-jobs` is set (default remains current mode)

- [ ] 4. Serialization and safety
  - [ ] 4.1 Store only file paths and small JSON payloads in Redis
  - [ ] 4.2 Organize artifacts by `address/mailbox/uidvalidity/uid.eml`
  - [ ] 4.3 Best-effort cleanup and optional checksum validation

- [ ] 5. Docs and examples
  - [ ] 5.1 Update README (job-mode quickstart, flags, compose services)
  - [ ] 5.2 Update AGENTS.md (job-mode guidance, testing patterns)

- [ ] 6. Tests and quality
  - [ ] 6.1 Add integration specs: enqueue + parallel fetch + single writer writes
  - [ ] 6.2 Add strict-mode spec for job failures (fetch/write)
  - [ ] 6.3 Lint (StandardRB/RuboCop) and full RSpec run (green)
