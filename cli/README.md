# NittyMail CLI (Docker Compose)

This folder provides a Docker-only workflow for the NittyMail CLI. You do not need Ruby installed locally — all commands run via Docker Compose.

## Prerequisites

- Docker and Docker Compose installed

## Setup

1. Copy the sample env and set your credentials:
   ```bash
   cp .env.sample .env
   # Edit .env and set NITTYMAIL_IMAP_ADDRESS and NITTYMAIL_IMAP_PASSWORD
   ```

2. Dependencies install automatically on first run (bundle install is run by the entrypoint). You can still run it manually if desired:
   ```bash
   docker compose run --rm cli bundle install
   ```

## Usage

### SQLite Quickstart

- Configure env (IMAP credentials and optional SQLite path):
  ```bash
  cp .env.sample .env
  # Edit .env and set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD
  # Optional: NITTYMAIL_SQLITE_DB to override the default DB file path
  ```

- Download messages into a local SQLite database:
  ```bash
  docker compose run --rm cli mailbox download \
    --mailbox INBOX \
    # default path is cli/data/[IMAP_ADDRESS].sqlite3 unless overridden
    # --database ./path/to/custom.sqlite3
  ```

### Notes on stored columns

- Each email row stores: address, mailbox, uidvalidity, uid, subject, internaldate, internaldate_epoch, rfc822_size, from_email, labels_json, raw (BLOB), plain_text, markdown. Indexes include a composite unique key and internaldate_epoch.

### Progress indicators

- The progress bar displays processed vs. total messages for the current download run.

### Performance tuning

- Flags:
  - `--max-fetch-size` IMAP fetch slice size (typical 200–500)
  - `--batch-size` DB upsert batch size (typical 100–500)

- Troubleshooting tips:
  - Ensure IMAP is enabled for your account; app password may be required.
  - Set `NITTYMAIL_SQLITE_DB` or use `--database` to control DB location.

- List mailboxes for your account. Flags are optional if env vars are set:
  ```bash
  # using env vars only
  docker compose run --rm cli mailbox list

  # or pass credentials explicitly
  docker compose run --rm cli mailbox list \
    -a "$NITTYMAIL_IMAP_ADDRESS" -p "$NITTYMAIL_IMAP_PASSWORD"
  ```

Agent guide: See `AGENTS.md` for CLI agent conventions and style.

- Open an interactive shell in the CLI container:
  ```bash
  docker compose run --rm cli bash
  ```

## Notes

- The Compose service mounts the repository root so the local gem at `../gem` (declared in `Gemfile`) is available in-container.
- No host Ruby required; all commands are executed via the `cli` service.
- Default DB path is `cli/data/[IMAP_ADDRESS].sqlite3` unless overridden by `--database` or `NITTYMAIL_SQLITE_DB`.
