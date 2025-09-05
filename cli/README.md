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

- Tuning tips:
  - If IMAP is slow but CPU is free, increase `--max-fetch-size` moderately (watch for server limits).
  - If SQLite writes are the bottleneck, reduce `--batch-size` to limit transaction pressure, or leave defaults and let WAL absorb bursts.
  - Re-run the command anytime; it only fetches missing UIDs (see “Resumability and WAL”).

### Resumability and WAL

- Resumable runs: the command diffs server UIDs against rows already in `emails` by (`address`, `mailbox`, `uidvalidity`, `uid`) and fetches only missing ones. Re-running only processes new mail.
- SQLite WAL: journaling is enabled with reasonable pragmas for higher write throughput during bulk inserts while maintaining durability. This is configured automatically in the ActiveRecord connector.

### Error handling

- Default: skips per-message parse/encoding errors and failing fetch batches with clear warnings.
- Strict mode: pass `--strict` to fail-fast (helpful in CI or when debugging data problems).

### Maintenance flags

- `--recreate`: Drop and rebuild rows for the current mailbox generation (scoped to `address` + `mailbox` + `uidvalidity` discovered during preflight). Requires confirmation unless `--yes`/`--force` is provided.
- `--purge-uidvalidity <n>`: Delete all rows for the specified UIDVALIDITY and exit (no download).
- `--yes` / `--force`: Skip confirmation prompts for destructive actions.

Examples:

```bash
# Drop and re-download the current generation for INBOX
docker compose run --rm cli mailbox download --mailbox INBOX --recreate --yes

# Purge an old generation and exit
docker compose run --rm cli mailbox download --mailbox INBOX --purge-uidvalidity 12345 --yes
```

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
