# Spec Tasks

## Tasks

- [ ] 1. Initialize SQLite + ActiveRecord foundation
  - [ ] 1.1 Write tests for database setup (connection, schema presence)
  - [ ] 1.2 Add gems: activerecord, sqlite3, activesupport; bundle install
  - [ ] 1.3 Add `utils/db.rb` ActiveRecord connector (WAL, pragmas, config via env/flag)
  - [ ] 1.4 Create migration `CreateEmails` with columns and indexes per spec
  - [ ] 1.5 Add `models/email.rb` ActiveRecord model with validations and helpers
  - [ ] 1.6 Provide simple migration runner hook (autoload/run at CLI start)
  - [ ] 1.7 Verify all tests pass

- [ ] 2. Replace Chroma-based CLI with SQLite-backed download
  - [ ] 2.1 Write tests for `cli mailbox download` behavior (idempotent, resumable, columns populated)
  - [ ] 2.2 Remove Chroma dependencies/usages (code, commands, utils); simplify CLI surface
  - [ ] 2.3 Rewrite `commands/mailbox.rb download` to use nittymail IMAP + ActiveRecord
  - [ ] 2.4 Implement preflight + diff using DB composite key (address, mailbox, uidvalidity, uid)
  - [ ] 2.5 Implement batched fetch + transactional inserts (skip existing)
  - [ ] 2.6 Emit concise progress with counts; graceful SIGINT handling
  - [ ] 2.7 Verify all tests pass

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
  - [ ] 4.2 Remove Chroma service from docker-compose; update env samples if needed
  - [ ] 4.3 Update CLI help and README to reflect SQLite backend and new flags
  - [ ] 4.4 Add guidance for performance flags (batch size, threads if any), WAL, and resume behavior
  - [ ] 4.5 Verify all tests pass

- [ ] 5. Quality, lint, and integration checks
  - [ ] 5.1 Write integration spec: small inbox fetch scenario with mocked IMAP; verify resumability
  - [ ] 5.2 StandardRB auto-fix, RuboCop clean
  - [ ] 5.3 Run full RSpec suite inside Docker; ensure green
  - [ ] 5.4 Verify all tests pass
