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
    --database ./nittymail.sqlite3
  ```

### Notes on stored columns

- Each email row stores: address, mailbox, uidvalidity, uid, subject, internaldate, internaldate_epoch, rfc822_size, from_email, labels_json, raw (BLOB), plain_text, markdown. Indexes include a composite unique key and internaldate_epoch.

### Progress indicators

- Download (`mailbox download`) progress title shows live status:
  - `f:X/Y`: producer threads alive/total
  - `u:X/Y`: consumer threads alive/total
  - `jq:N`: job queue size (pending uploads)
  - `fq:N`: fetch queue size (pending IMAP batches)

- Backfill (`db backfill`) progress title shows:
  - `add:N`: pending variant embeddings to upload for the current page
  - `page:P`: current page index
  - `rq:N`: raw documents processed in the current page
  - `added:N`: total variants uploaded so far

### Tuning & backpressure

- Bounded queues with backpressure are enabled by default:
  - Fetch queue (`fq`) is a small buffer of pending IMAP batches (capacity ≈ `fetch_threads*4`).
  - Job queue (`jq`) is a small buffer of pending upload chunks (capacity ≈ `upload_threads*4`).
- Reading the gauges:
  - `jq` consistently high → uploads are the bottleneck (increase `--upload-threads` or reduce fetch rate).
  - `fq` consistently at capacity → fetchers are the bottleneck (increase `--fetch-threads` or `--max-fetch-size`).
  - If both are low and progress is slow, consider raising both thread counts (watch CPU and IMAP limits).
- Practical starting points:
  - `--fetch-threads 4` and `--max-fetch-size 200–500` for larger mailboxes.
  - `--upload-threads 2–4` and `--upload-batch-size 200–500` for stable Chroma uploads.



- Performance tuning (flags):
  - `--upload-batch-size 200` (upload chunk size)
  - `--upload-threads 4` (concurrent upload workers)
  - `--fetch-threads 2` (concurrent IMAP fetchers)
  - `--max-fetch-size 50` (IMAP fetch slice size)

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
