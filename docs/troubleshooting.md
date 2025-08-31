# Troubleshooting

## Mailbox Aborts (Retries Exhausted)

- Symptom: A line like `Aborting mailbox '[Gmail]/All Mail' after 3 failed attempt(s) due to OpenSSL::SSL::SSLError: SSL_read: unexpected eof while reading; proceeding to next mailbox` followed by a full Ruby backtrace.
- Meaning: Repeated errors occurred while fetching a UID batch for that mailbox. After the configured retry limit, sync skips the mailbox and moves on. Any post-processing (e.g., pruning) for that mailbox is skipped.
- What to check:
  - Inspect the backtrace to locate the failing component (usually `lib/nittymail/imap_client.rb#fetch_with_retry`).
  - Look for Gmail connection limits or transient network issues (SSL/IO errors).
  - Note if failures repeat for the same mailbox/UIDs across runs.
- Remediation tips:
  - Increase retries: `docker compose run --rm ruby ./cli.rb sync --retry-attempts 5` (or `RETRY_ATTEMPTS=5`).
  - Reduce concurrency to stay under Gmail’s limits: `--threads 1-4` and moderate `--mailbox-threads`.
  - Re-run the sync; transient failures often succeed on the next attempt.
  - Enable strict mode to fail fast for easier diagnosis: `--strict-errors`.
  - Temporarily limit scope to reproduce quickly: `--only "INBOX"` or `--ignore-mailboxes "[Gmail]/*"`.

Notes:
- Abort logs include the exception class, message, and full backtrace for diagnosis.
- For persistent failures tied to specific messages, consider opening an issue with the log snippet and the minimal flags you used.

