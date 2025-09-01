# Changelog

All notable changes in the `feat/library-api` branch are documented here.

## 2025-09-01 (feat/library-api)

- Library API and structure
  - Added public entrypoints: `core/lib/nittymail.rb` and `NittyMail::API` facade
  - Extracted sync helpers to `core/lib/nittymail/sync_utils.rb` (filtering, prune/purge, preflight worker, mailbox processing)
  - Consolidated reporting to a single `reporter.event(type, payload)` hook
  - CLI uses a progress-bar reporter; library calls are silent by default

- Enrich improvements
  - Default: skip already-enriched rows (`rfc822_size IS NULL`)
  - Added `--regenerate` flag to re-enrich everything
  - Created partial index `email_idx_rfc822_size_null` to speed up scans

- Embed improvements
  - Added reporter events and structured error counts in finished/interrupted events
  - Refactored loops to idiomatic Ruby (`while !stop_requested`)

- Sync orchestration
  - Reporter events throughout preflight and mailbox processing
  - Mailbox summary event with `{ total, prune_candidates, pruned, purged, processed, errors, result }`
  - Testable helpers: `preflight_worker_with_imap`, `process_mailbox`

- Tests and style
  - Adopted `rspec-given` for new specs (Given/When/Then)
  - Added unit tests for reporter events and sync utilities
  - Added integration test scaffolding with cassette record/replay

- Integration cassettes (IMAP)
  - New `IMAPTape` to record/replay preflight and fetch responses as JSON
  - Full-body recording by default
  - Rake tasks: `cassette:record[MAILBOXES]`, `cassette:replay`

- Documentation
  - Library usage and reporter event schema documented in `core/README.md`
  - Agent guidance and event schema reference added to `AGENTS.md`
  - Integration cassette workflow documented in `core/README.md`

- Licensing
  - Added missing AGPL headers and updated copyright to 2025 across files

