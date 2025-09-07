# NittyMail CLI Command Reference

This document provides a comprehensive reference for all NittyMail CLI commands and their options.

## Quick Start

```bash
# Setup environment
cd cli
cp .env.sample .env
# Edit .env with your IMAP credentials

# List mailboxes
docker compose run --rm cli mailbox list

# Download emails
docker compose run --rm cli mailbox download --mailbox INBOX

# Archive emails
docker compose run --rm cli mailbox archive --mailbox INBOX

# Start MCP server
docker compose run --rm cli db mcp
```

## Environment Variables

All commands support these environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `NITTYMAIL_IMAP_ADDRESS` | IMAP account email | Required for IMAP commands |
| `NITTYMAIL_IMAP_PASSWORD` | IMAP password/app password | Required for IMAP commands |
| `NITTYMAIL_SQLITE_DB` | SQLite database path | `cli/data/[ADDRESS].sqlite3` |
| `NITTYMAIL_MAX_FETCH_SIZE` | IMAP max fetch size | Settings default (200) |
| `NITTYMAIL_MCP_MAX_LIMIT` | Max rows for MCP queries | 1000 |
| `NITTYMAIL_QUIET` | Reduce stderr logging | `false` |

## Commands

### `mailbox list`

Lists all available IMAP mailboxes.

```bash
docker compose run --rm cli mailbox list [options]
```

**Options:**
- `-a, --address ADDRESS` - IMAP account email (required)
- `-p, --password PASSWORD` - IMAP password/app password (required)

**Examples:**
```bash
docker compose run --rm cli mailbox list
docker compose run --rm cli mailbox list -a user@gmail.com -p password
```

### `mailbox download`

Downloads emails from IMAP server to local SQLite database.

```bash
docker compose run --rm cli mailbox download [options]
```

**Options:**
- `-m, --mailbox MAILBOX` - Mailbox name (default: INBOX)
- `--database PATH` - SQLite database path
- `--batch-size SIZE` - DB upsert batch size (default: 200)
- `--max-fetch-size SIZE` - IMAP max fetch size
- `-a, --address ADDRESS` - IMAP account email (required)
- `-p, --password PASSWORD` - IMAP password/app password (required)
- `--strict` - Fail-fast on errors instead of skipping
- `--recreate` - Drop and recreate rows for this mailbox+uidvalidity
- `-y, --yes` - Auto-confirm destructive actions
- `--force` - Alias for `--yes`
- `--purge-uidvalidity ID` - Delete rows for a specific UIDVALIDITY and exit

**Examples:**
```bash
# Basic download
docker compose run --rm cli mailbox download --mailbox INBOX

# Download with custom database
docker compose run --rm cli mailbox download --mailbox INBOX --database ./my-emails.sqlite3

# Download Gmail All Mail
docker compose run --rm cli mailbox download --mailbox "[Gmail]/All Mail"

# Recreate mailbox data
docker compose run --rm cli mailbox download --mailbox INBOX --recreate --yes

# Purge old UIDVALIDITY
docker compose run --rm cli mailbox download --mailbox INBOX --purge-uidvalidity 12345 --yes
```

### `mailbox archive`

Archives raw email files to local filesystem as .eml files.

```bash
docker compose run --rm cli mailbox archive [options]
```

**Options:**
- `-m, --mailbox MAILBOX` - Mailbox name (default: INBOX)
- `--output PATH` - Archive output base directory (default: cli/archives)
- `--max-fetch-size SIZE` - IMAP max fetch size
- `-a, --address ADDRESS` - IMAP account email (required)
- `-p, --password PASSWORD` - IMAP password/app password (required)
- `--strict` - Fail-fast on errors instead of skipping
- `--only-preflight` - Only perform preflight and list UIDs (no files created)
- `--only-ids UID1,UID2` - Skip preflight and download specific UIDs
- `-y, --yes` - Auto-confirm overwriting existing files

**Examples:**
```bash
# Basic archive
docker compose run --rm cli mailbox archive --mailbox INBOX

# Archive to custom directory
docker compose run --rm cli mailbox archive --mailbox INBOX --output ./my-archives

# List UIDs that would be archived
docker compose run --rm cli mailbox archive --mailbox INBOX --only-preflight

# Archive specific UIDs
docker compose run --rm cli mailbox archive --mailbox INBOX --only-ids 123,456,789

# Archive with auto-confirmation
docker compose run --rm cli mailbox archive --mailbox INBOX --yes
```

### `db mcp`

Starts Model Context Protocol server for AI agent access to email database.

```bash
docker compose run --rm cli db mcp [options]
```

**Options:**
- `--database PATH` - SQLite database path
- `--address ADDRESS` - Email address context
- `--max-limit LIMIT` - Max rows for list endpoints (default: 1000)
- `--quiet` - Reduce stderr logging

**Examples:**
```bash
# Start MCP server
docker compose run --rm cli db mcp

# Start with custom database
docker compose run --rm cli db mcp --database ./my-emails.sqlite3

# Start with limits
docker compose run --rm cli db mcp --max-limit 500 --quiet
```

## MCP Tools Available

When the MCP server is running, these tools are available to AI agents:

### Email Retrieval
- `db.list_earliest_emails` - Fetch earliest emails by date
- `db.get_email_full` - Single email with full content
- `db.filter_emails` - Search with filters
- `db.search_emails` - Vector search (stubbed)

### Analytics
- `db.get_email_stats` - Database overview
- `db.count_emails` - Count emails matching criteria
- `db.get_top_senders` - Most frequent senders
- `db.get_top_domains` - Most frequent sender domains
- `db.get_largest_emails` - Largest emails by size
- `db.get_mailbox_stats` - Email distribution per mailbox

### Time-based Analytics
- `db.get_emails_by_date_range` - Volume analytics
- `db.get_email_activity_heatmap` - Email patterns by hour/day
- `db.get_response_time_stats` - Response times in threads
- `db.get_email_frequency_by_sender` - Email frequency patterns
- `db.get_seasonal_trends` - Email volume trends by month/year

### Content Search
- `db.get_emails_with_attachments` - Filter emails with attachments
- `db.search_email_headers` - Search email headers
- `db.get_emails_by_keywords` - Keyword search with AND/OR logic

### Advanced
- `db.get_emails_by_size_range` - Filter by size categories
- `db.get_duplicate_emails` - Find duplicate emails
- `db.execute_sql_query` - Execute read-only SQL queries

## Performance Tuning

### IMAP Settings
- `--max-fetch-size`: Increase for faster downloads (watch server limits)
- Default: 200 messages per IMAP fetch

### Database Settings
- `--batch-size`: Adjust for SQLite write performance
- Default: 200 messages per database batch
- WAL mode enabled automatically for concurrent access

### Parallel Processing
Use the parallel archive script for faster archiving:
```bash
./cli/bin/archive.sh -- --mailbox INBOX
```

## Troubleshooting

### Common Issues

**"Could not find X in locally installed gems"**
```bash
docker compose run --rm cli bundle install
```

**IMAP Connection Issues**
- Verify Gmail IMAP is enabled
- Use app passwords for 2FA accounts
- Check network connectivity

**Database Lock Errors**
- Close other SQLite connections
- Use WAL mode (enabled by default)

**Permission Issues**
- Ensure Docker has access to output directories
- Check file permissions for database files

### Getting Help

```bash
# General help
docker compose run --rm cli --help

# Command-specific help
docker compose run --rm cli mailbox download --help
docker compose run --rm cli mailbox archive --help
docker compose run --rm cli db mcp --help
```

## File Structure

```
cli/
├── archives/           # Archived .eml files (gitignored)
├── data/              # SQLite databases (gitignored)
├── docs/              # Documentation
│   ├── CLI_REFERENCE.md    # This file
│   ├── MCP_TOOLS.md       # MCP tools reference
│   └── chroma.md          # Chroma integration docs
├── bin/               # Scripts
│   └── archive.sh      # Parallel archive script
├── commands/          # CLI command classes
├── models/            # ActiveRecord models
├── utils/             # Utility classes
├── cli.rb             # Main CLI entry point
└── docker-compose.yml # Docker services
```