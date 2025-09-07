# NittyMail

A Ruby-based system for synchronizing Gmail/IMAP accounts to local SQLite databases and providing email analysis tools through a Model Context Protocol (MCP) server.

## Features

- **Email Synchronization**: Download emails from Gmail/IMAP to local SQLite database
- **Raw Email Archiving**: Save emails as .eml files with Gmail metadata preservation
- **MCP Server**: AI agent access to email database with 23+ analysis tools
- **Docker Workflow**: No local Ruby installation required
- **Gmail Extensions**: Support for X-GM-LABELS, X-GM-MSGID, X-GM-THRID
- **Parallel Archive Script**: Bash script for parallel email archiving
- **Async Job Queue Archive**: Advanced async job queue with resumability and progress tracking

## Quick Start

```bash
# Clone the repository
git clone <repository-url>
cd nittymail

# Setup environment
cd cli
cp .env.sample .env
# Edit .env with your IMAP credentials

# List available mailboxes
docker compose run --rm cli mailbox list

# Download emails to SQLite
docker compose run --rm cli mailbox download --mailbox INBOX

# Archive emails to .eml files
docker compose run --rm cli mailbox archive --mailbox INBOX

# Async job queue archive (recommended for large mailboxes)
./cli/bin/archive_async.sh -- --mailbox INBOX

# Start MCP server for AI agent access
docker compose run --rm cli db mcp
```

## Project Structure

```
nittymail/
├── cli/                    # Main CLI application
│   ├── commands/          # Thor-based CLI commands
│   ├── models/            # ActiveRecord models
│   ├── docs/              # CLI documentation
│   │   ├── CLI_REFERENCE.md   # Complete command reference
│   │   └── MCP_TOOLS.md      # MCP tools documentation
│   ├── bin/
│   │   ├── archive.sh         # Parallel archive script
│   │   └── archive_async.sh   # Async job queue archive script
├── gem/                   # NittyMail Ruby gem
│   └── lib/nitty_mail/    # Core IMAP/email processing
├── docs/                  # Project documentation
└── AGENTS.md              # AI agent development guide
```

## Documentation

- **[CLI Reference](cli/docs/CLI_REFERENCE.md)** - Complete command reference with all options
- **[CLI Setup Guide](cli/README.md)** - Docker setup and basic CLI usage
- **[MCP Tools](cli/docs/MCP_TOOLS.md)** - Documentation for all 23 MCP database tools
- **[Agent Guide](AGENTS.md)** - Development guidelines for AI agents
- **[Gem README](gem/README.md)** - Ruby gem documentation

## Commands Overview

### Mailbox Operations
```bash
# List IMAP mailboxes
docker compose run --rm cli mailbox list

# Download emails to SQLite database
docker compose run --rm cli mailbox download --mailbox INBOX

# Archive emails to .eml files
docker compose run --rm cli mailbox archive --mailbox INBOX
```

### Database Operations
```bash
# Start MCP server for AI agents
docker compose run --rm cli db mcp --database ./emails.sqlite3
```

### Parallel Archive Script
```bash
# Use parallel archive script for faster email archiving
# This script spawns multiple processes to archive emails concurrently
./cli/bin/archive.sh -- --mailbox INBOX
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `NITTYMAIL_IMAP_ADDRESS` | IMAP account email | Required |
| `NITTYMAIL_IMAP_PASSWORD` | IMAP password/app password | Required |
| `NITTYMAIL_SQLITE_DB` | SQLite database path | `cli/data/[ADDRESS].sqlite3` |
| `NITTYMAIL_MAX_FETCH_SIZE` | IMAP batch size | 200 |
| `NITTYMAIL_MCP_MAX_LIMIT` | MCP query limit | 1000 |

## MCP Tools Available

The MCP server provides 23+ tools for email analysis:

### Email Retrieval
- `db.list_earliest_emails`, `db.get_email_full`, `db.filter_emails`
- `db.search_emails` (vector search stub)

### Analytics
- `db.get_email_stats`, `db.get_top_senders`, `db.get_top_domains`
- `db.get_largest_emails`, `db.get_mailbox_stats`

### Time-based Analysis
- `db.get_emails_by_date_range`, `db.get_email_activity_heatmap`
- `db.get_response_time_stats`, `db.get_seasonal_trends`

### Content Search
- `db.search_email_headers`, `db.get_emails_by_keywords`
- `db.get_emails_with_attachments`

### Advanced Features
- `db.get_emails_by_size_range`, `db.get_duplicate_emails`
- `db.execute_sql_query` (read-only SQL)

## Requirements

- Docker and Docker Compose
- Gmail/IMAP account with IMAP enabled
- App password (for Gmail 2FA accounts)

## Development

```bash
# Run CLI tests
docker compose run --rm cli bundle exec rspec -fd -b spec/

# Run gem tests
cd gem && bundle exec rspec -fd -b

# Lint code
docker compose run --rm cli bundle exec standardrb --fix
```

## License

See [COPYING](COPYING) file for license information.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes with tests
4. Run the full test suite
5. Submit a pull request

See [AGENTS.md](AGENTS.md) for detailed development guidelines.