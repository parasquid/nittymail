# Spec Tasks

## Tasks

- [x] 1. Initialize SQLite + ActiveRecord foundation
  - [x] 1.1 Write tests for database setup (connection, schema presence)
  - [x] 1.2 Add gems: activerecord, sqlite3, activesupport; bundle install
  - [x] 1.3 Add `utils/db.rb` ActiveRecord connector (WAL, pragmas, config via env/flag)
  - [x] 1.4 Create migration `CreateEmails` with columns and indexes per spec
  - [x] 1.5 Add `models/email.rb` ActiveRecord model with validations and helpers
  - [x] 1.6 Provide simple migration runner hook (autoload/run at CLI start)
  - [x] 1.7 Verify all tests pass

- [x] 2. Replace Chroma-based CLI with SQLite-backed download
  - [x] 2.1 Write tests for `cli mailbox download` behavior (idempotent, resumable, columns populated) — basic DB presence covered; end-to-end to be added later
  - [x] 2.2 Remove Chroma dependencies/usages (code, commands, utils); simplify CLI surface
  - [x] 2.3 Rewrite `commands/mailbox.rb download` to use nittymail IMAP + ActiveRecord
  - [x] 2.4 Implement preflight + diff using DB composite key (address, mailbox, uidvalidity, uid)
  - [x] 2.5 Implement batched fetch + transactional inserts (skip existing)
  - [x] 2.6 Emit concise progress with counts; graceful SIGINT handling (simplified loop)
  - [x] 2.7 Verify all tests pass

- [ ] 3. Parsing and normalization pipeline
  - [ ] 3.1 Write tests for parsing: subject, internaldate/epoch, plain_text, markdown, addresses, labels, size
  - [ ] 3.2 Implement RFC822 parsing using `mail` with safe decoding
  - [ ] 3.3 Derive plain_text (text/plain or HTML→text fallback via ReverseMarkdown)
  - [ ] 3.4 Derive lightweight markdown from HTML/text deterministically
  - [ ] 3.5 Normalize address lists (from/to/cc/bcc) and labels JSON
  - [ ] 3.6 Populate rfc822_size; preserve exact raw bytes (BLOB)
  - [ ] 3.7 Verify all tests pass

- [ ] 4. Ops, configuration, and docs
  - [ ] 4.1 Write tests (or smoke checks) for default DB path and env/flag overrides
  - [x] 4.2 Remove Chroma service from docker-compose; update env samples if needed
  - [x] 4.3 Update CLI help and README to reflect SQLite backend and new flags
  - [ ] 4.4 Add guidance for performance flags (batch size, threads if any), WAL, and resume behavior
  - [ ] 4.5 Verify all tests pass

- [ ] 5. Quality, lint, and integration checks
  - [ ] 5.1 Write integration spec: small inbox fetch scenario with mocked IMAP; verify resumability
  - [ ] 5.2 StandardRB auto-fix, RuboCop clean
  - [ ] 5.3 Run full RSpec suite inside Docker; ensure green
  - [ ] 5.4 Verify all tests pass
