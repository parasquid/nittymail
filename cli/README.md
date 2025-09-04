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

2. Start Chroma (vector DB) locally via Compose:
   ```bash
   docker compose up -d chroma
   ```

3. Dependencies install automatically on first run (bundle install is run by the entrypoint). You can still run it manually if desired:
   ```bash
   docker compose run --rm cli bundle install
   ```

## Usage

### Chroma Quickstart

- Configure env (host + IMAP credentials):
  ```bash
  cp .env.sample .env
  # Edit .env and set NITTYMAIL_IMAP_ADDRESS/NITTYMAIL_IMAP_PASSWORD
  # Optional: NITTYMAIL_CHROMA_HOST (default works with Compose): http://chroma:8000
  ```

- Start Chroma DB:
  ```bash
  docker compose up -d chroma
  ```

- Download messages into a Chroma collection:
  ```bash
  docker compose run --rm cli mailbox download
  # or with options
  docker compose run --rm cli mailbox download \
    --mailbox INBOX \
    --collection my-mails
  ```

- Performance tuning (flags):
  - `--upload-batch-size 200` (upload chunk size)
  - `--upload-threads 4` (concurrent upload workers)
  - `--max-fetch-size 50` (IMAP fetch slice size)

- Troubleshooting tips:
  - Use Docker service host: `http://chroma:8000` (not localhost)
  - Check server: `docker compose run --rm cli curl -i http://chroma:8000/api/v1/version`
  - Enable client logs: `CHROMA_LOG=1 docker compose run --rm cli mailbox download`

- List mailboxes for your account. Flags are optional if env vars are set:
  ```bash
  # using env vars only
  docker compose run --rm cli mailbox list

  # or pass credentials explicitly
  docker compose run --rm cli mailbox list \
    -a "$NITTYMAIL_IMAP_ADDRESS" -p "$NITTYMAIL_IMAP_PASSWORD"
  ```

- Download new emails into a Chroma collection (uses preflight + Chroma check):
  ```bash
  # Defaults: mailbox INBOX, collection name derived from address+mailbox, host from NITTYMAIL_CHROMA_HOST
  docker compose run --rm cli mailbox download

  # Custom mailbox / collection
  docker compose run --rm cli mailbox download \
    --mailbox "[Gmail]/All Mail" \
    --collection "custom-collection-name"
  ```

Tip: The default `NITTYMAIL_CHROMA_HOST` in `.env.sample` points to the bundled `chroma` service (`http://chroma:8000`).

Persistence:
- Chroma data persists in `cli/chroma-data` (bind-mounted to `/chroma/chroma` in the container).
- Do not use `docker compose down -v` unless you want to delete data; `-v` removes volumes including bind targets.
- Avoid mounting `/chroma` root; it overlays the app code and breaks startup.
- Verify persistence: `docker compose run --rm cli ls -la chroma-data`.

Agent docs: See `AGENTS_CHROMA.md` for using the `chroma-db` gem in code (collections, paging, batching, and troubleshooting).

- Open an interactive shell in the CLI container:
  ```bash
  docker compose run --rm cli bash
  ```

## Notes

- The Compose service mounts the repository root so the local gem at `../gem` (declared in `Gemfile`) is available in-container.
- No host Ruby required; all commands are executed via the `cli` service.
