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

#### Download Command Options

```bash
docker compose run --rm cli mailbox download [options]
```

**Required Options:**
- `-m, --mailbox MAILBOX` - Mailbox name (default: INBOX)
- `-a, --address ADDRESS` - IMAP account email (or env: `NITTYMAIL_IMAP_ADDRESS`)
- `-p, --password PASSWORD` - IMAP password/app password (or env: `NITTYMAIL_IMAP_PASSWORD`)

**Optional Flags:**
- `--database PATH` - SQLite database path (default: `NITTYMAIL_SQLITE_DB` or `cli/data/[ADDRESS].sqlite3`)
- `--batch-size SIZE` - DB upsert batch size (default: 200)
- `--max-fetch-size SIZE` - IMAP max fetch size (env: `NITTYMAIL_MAX_FETCH_SIZE`, default: Settings#max_fetch_size)
- `--strict` - Fail-fast on errors instead of skipping
- `--recreate` - Drop and recreate rows for this mailbox+uidvalidity
- `-y, --yes` - Auto-confirm destructive actions
- `--force` - Alias for `--yes`
- `--purge-uidvalidity ID` - Delete rows for a specific UIDVALIDITY and exit

**Environment Variables:**
- `NITTYMAIL_IMAP_ADDRESS` - IMAP account email
- `NITTYMAIL_IMAP_PASSWORD` - IMAP password/app password
- `NITTYMAIL_SQLITE_DB` - SQLite database path
- `NITTYMAIL_MAX_FETCH_SIZE` - IMAP max fetch size



Mailbox examples (Gmail names often include brackets and spaces; be sure to quote):

```bash
# List all mailboxes (uses credentials from .env)
docker compose run --rm cli mailbox list

# Download Sent Mail
docker compose run --rm cli mailbox download --mailbox "[Gmail]/Sent Mail"

# Download All Mail  
docker compose run --rm cli mailbox download --mailbox "[Gmail]/All Mail"

# Download a custom label
docker compose run --rm cli mailbox download --mailbox "Receipts"
```

### Archive Raw Mail (.eml files)

Archive saves raw RFC822 email files named by UID without parsing or database writes. It runs in single-process mode.

#### Command Options

```bash
docker compose run --rm cli mailbox archive [options]
```

**Required Options:**
- `-m, --mailbox MAILBOX` - Mailbox name (default: INBOX)
- `-a, --address ADDRESS` - IMAP account email (or env: `NITTYMAIL_IMAP_ADDRESS`)
- `-p, --password PASSWORD` - IMAP password/app password (or env: `NITTYMAIL_IMAP_PASSWORD`)

**Optional Flags:**
- `--output PATH` - Archive output base directory (default: `cli/archives`)
- `--max-fetch-size SIZE` - IMAP max fetch size (env: `NITTYMAIL_MAX_FETCH_SIZE`, default: Settings#max_fetch_size)
- `--strict` - Fail-fast on errors instead of skipping
- `--only-preflight` - Only perform preflight and list UIDs to be archived (no files created)
- `--only-ids UID1,UID2` - Skip preflight and only download specific UIDs (comma-separated list)
- `-y, --yes` - Auto-confirm overwriting existing files

**Environment Variables:**
- `NITTYMAIL_IMAP_ADDRESS` - IMAP account email
- `NITTYMAIL_IMAP_PASSWORD` - IMAP password/app password
- `NITTYMAIL_MAX_FETCH_SIZE` - IMAP max fetch size

Mailbox examples for archive:

```bash
# Archive Sent Mail (uses credentials from .env)
docker compose run --rm cli mailbox archive --mailbox "[Gmail]/Sent Mail"

# Archive a custom label
docker compose run --rm cli mailbox archive --mailbox "Receipts"

# List UIDs that would be archived (no files created)
docker compose run --rm cli mailbox archive --mailbox INBOX --only-preflight

# Archive specific UIDs only
docker compose run --rm cli mailbox archive --mailbox INBOX --only-ids 123,456,789

# Archive with auto-confirmation for overwriting existing files
docker compose run --rm cli mailbox archive --mailbox INBOX --yes
```

### Async Job Queue Archive (Recommended for Large Mailboxes)

For large mailboxes, use the async job queue archive script for better performance and resumability:

```bash
./cli/bin/archive_async.sh [options] -- [mailbox arguments]
```

**Features:**
- 🚀 **Parallel Processing**: Multiple workers process jobs simultaneously
- 🔄 **Resumable**: Continue after interruptions without re-running preflight
- 📊 **Progress Tracking**: Real-time progress monitoring
- 💾 **Persistent Queue**: Job queue survives script restarts
- 🧹 **Auto Cleanup**: Fresh starts clear previous job queues

**Examples:**
```bash
# Fresh archive with job queue
./cli/bin/archive_async.sh -- --mailbox INBOX

# Resume interrupted archive (skips preflight!)
./cli/bin/archive_async.sh --resume -- --mailbox INBOX

# Debug mode with custom mailbox
./cli/bin/archive_async.sh --debug -- --mailbox "[Gmail]/All Mail"

# Clean up job queue
./cli/bin/archive_async.sh --cleanup
```

**How It Works:**
1. **Fresh Start**: Runs preflight once, creates job queue, starts parallel workers
2. **Resume**: Loads existing jobs, continues processing (no preflight needed)
3. **Workers**: Multiple parallel processes handle batches of emails
4. **Queue**: Jobs persist to disk and survive interruptions

### MCP Server for Email Database

Run a local Model Context Protocol (MCP) server that exposes email database tools over stdio. This allows MCP-compatible AI agents to query your local email database without requiring cloud access or IMAP connections.

#### MCP Server Command Options

```bash
docker compose run --rm cli db mcp [options]
```

**Optional Flags:**
- `--database PATH` - SQLite database path (env: `NITTYMAIL_SQLITE_DB` or `cli/data/[ADDRESS].sqlite3`)
- `--address ADDRESS` - Email address context (env: `NITTYMAIL_IMAP_ADDRESS`)
- `--max-limit LIMIT` - Max rows for list endpoints (env: `NITTYMAIL_MCP_MAX_LIMIT`, default: 1000)
- `--quiet` - Reduce stderr logging (env: `NITTYMAIL_QUIET`)

**Environment Variables:**
- `NITTYMAIL_SQLITE_DB` - SQLite database path
- `NITTYMAIL_IMAP_ADDRESS` - Email address context
- `NITTYMAIL_MCP_MAX_LIMIT` - Max rows for list endpoints (default: 1000)
- `NITTYMAIL_QUIET` - Reduce stderr logging (set to "1" to enable)

**Examples:**
```bash
# Start MCP server with default settings
docker compose run --rm cli db mcp

# Start with custom database and limits
docker compose run --rm cli db mcp \
  --database ./my-emails.sqlite3 \
  --max-limit 500 \
  --quiet
```

- **Available MCP Tools (23 total)**:
  - **Email Retrieval**: `db.list_earliest_emails`, `db.get_email_full`, `db.filter_emails`
  - **Analytics**: `db.get_email_stats`, `db.get_top_senders`, `db.get_top_domains`, `db.get_largest_emails`, `db.get_mailbox_stats`
  - **Date/Time Analysis**: `db.get_emails_by_date_range`, `db.get_email_activity_heatmap`, `db.get_seasonal_trends`
  - **Thread Analysis**: `db.get_email_thread`, `db.get_response_time_stats`, `db.get_email_frequency_by_sender`
  - **Content Search**: `db.search_email_headers`, `db.get_emails_by_keywords`, `db.get_emails_with_attachments`
  - **Advanced Features**: `db.get_emails_by_size_range`, `db.get_duplicate_emails`, `db.execute_sql_query`
  - **Utilities**: `db.count_emails`, `db.search_emails` (stubbed for future vector search)

- **Security Features**:
  - Read-only database access (no writes, updates, or deletes)
  - SQL injection prevention with parameter binding
  - Query limits enforced (configurable max 1000 rows)
  - LIKE pattern sanitization to prevent wildcard abuse
  - Restricted to SELECT/WITH queries only

- **Usage with MCP Clients**:
  - The server communicates via JSON-RPC 2.0 over stdio
  - Compatible with MCP-enabled AI agents and development tools
  - No network connections required - purely local database access
  - Supports environment variable configuration for automation

- Output layout: `cli/archives/<address>/<mailbox>/<uidvalidity>/<uid>.eml`.
  - The `cli/archives/.keep` file is tracked; all other archive files are gitignored to prevent accidental commits.
- Resumable: re‑running archives only missing UIDs; existing `<uid>.eml` files are skipped.
- Progress: progress bar reflects processed vs total.
- Interrupts: first Ctrl‑C sets `nm:arc:<run_id>:aborted=1`, stops enqueues/polling, and cleans temporary files; second Ctrl‑C forces exit.

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
# Drop and re-download the current generation for INBOX (uses credentials from .env)
docker compose run --rm cli mailbox download --mailbox INBOX --recreate --yes

# Purge an old generation and exit
docker compose run --rm cli mailbox download --mailbox INBOX --purge-uidvalidity 12345 --yes
```

- Troubleshooting tips:
  - Ensure IMAP is enabled for your account; app password may be required.
  - Set `NITTYMAIL_SQLITE_DB` or use `--database` to control DB location.

#### List Command Options

```bash
docker compose run --rm cli mailbox list [options]
```

**Required Options:**
- `-a, --address ADDRESS` - IMAP account email (or env: `NITTYMAIL_IMAP_ADDRESS`)
- `-p, --password PASSWORD` - IMAP password/app password (or env: `NITTYMAIL_IMAP_PASSWORD`)

**Environment Variables:**
- `NITTYMAIL_IMAP_ADDRESS` - IMAP account email
- `NITTYMAIL_IMAP_PASSWORD` - IMAP password/app password

**Examples:**
```bash
# List mailboxes using environment variables
docker compose run --rm cli mailbox list

# Override credentials
docker compose run --rm cli mailbox list \
  -a "your@email.com" -p "your-app-password"
```

Agent guide: See `AGENTS.md` for CLI agent conventions and style.

- Open an interactive shell in the CLI container:
  ```bash
  docker compose run --rm cli bash
  ```

## Complete Command Reference

### `mailbox list` - List IMAP Mailboxes
Lists all available mailboxes on the IMAP server.

**Usage:** `docker compose run --rm cli mailbox list [options]`

**Options:**
- `-a, --address ADDRESS` - IMAP account email (required, or env: `NITTYMAIL_IMAP_ADDRESS`)
- `-p, --password PASSWORD` - IMAP password/app password (required, or env: `NITTYMAIL_IMAP_PASSWORD`)

### `mailbox download` - Download Emails to SQLite
Downloads emails from IMAP server to local SQLite database.

**Usage:** `docker compose run --rm cli mailbox download [options]`

**Options:**
- `-m, --mailbox MAILBOX` - Mailbox name (default: INBOX)
- `--database PATH` - SQLite database path (default: `cli/data/[ADDRESS].sqlite3`)
- `--batch-size SIZE` - DB upsert batch size (default: 200)
- `--max-fetch-size SIZE` - IMAP max fetch size (default: Settings#max_fetch_size)
- `-a, --address ADDRESS` - IMAP account email (required, or env: `NITTYMAIL_IMAP_ADDRESS`)
- `-p, --password PASSWORD` - IMAP password/app password (required, or env: `NITTYMAIL_IMAP_PASSWORD`)
- `--strict` - Fail-fast on errors instead of skipping
- `--recreate` - Drop and recreate rows for this mailbox+uidvalidity
- `-y, --yes` - Auto-confirm destructive actions
- `--force` - Alias for `--yes`
- `--purge-uidvalidity ID` - Delete rows for a specific UIDVALIDITY and exit

### `mailbox archive` - Archive Emails to .eml Files
Archives raw email files to local filesystem.

**Usage:** `docker compose run --rm cli mailbox archive [options]`

**Options:**
- `-m, --mailbox MAILBOX` - Mailbox name (default: INBOX)
- `--output PATH` - Archive output base directory (default: `cli/archives`)
- `--max-fetch-size SIZE` - IMAP max fetch size (default: Settings#max_fetch_size)
- `-a, --address ADDRESS` - IMAP account email (required, or env: `NITTYMAIL_IMAP_ADDRESS`)
- `-p, --password PASSWORD` - IMAP password/app password (required, or env: `NITTYMAIL_IMAP_PASSWORD`)
- `--strict` - Fail-fast on errors instead of skipping
- `--only-preflight` - Only perform preflight and list UIDs (no files created)
- `--only-ids UID1,UID2` - Skip preflight and download specific UIDs
- `-y, --yes` - Auto-confirm overwriting existing files

### `db mcp` - Start MCP Server
Runs Model Context Protocol server for AI agent access.

**Usage:** `docker compose run --rm cli db mcp [options]`

**Options:**
- `--database PATH` - SQLite database path (default: `cli/data/[ADDRESS].sqlite3`)
- `--address ADDRESS` - Email address context (or env: `NITTYMAIL_IMAP_ADDRESS`)
- `--max-limit LIMIT` - Max rows for list endpoints (default: 1000)
- `--quiet` - Reduce stderr logging

## Environment Variables

All commands support these environment variables:

- `NITTYMAIL_IMAP_ADDRESS` - IMAP account email
- `NITTYMAIL_IMAP_PASSWORD` - IMAP password/app password
- `NITTYMAIL_SQLITE_DB` - SQLite database path
- `NITTYMAIL_MAX_FETCH_SIZE` - IMAP max fetch size
- `NITTYMAIL_MCP_MAX_LIMIT` - Max rows for MCP list endpoints (default: 1000)
- `NITTYMAIL_QUIET` - Reduce stderr logging (set to "1" to enable)

## Notes

- The Compose service mounts the repository root so the local gem at `../gem` (declared in `Gemfile`) is available in-container.
- No host Ruby required; all commands are executed via the `cli` service.
- Default DB path is `cli/data/[IMAP_ADDRESS].sqlite3` unless overridden by `--database` or `NITTYMAIL_SQLITE_DB`.
