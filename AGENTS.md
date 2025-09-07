# NittyMail Project Guide for AI Agents

This comprehensive guide provides AI agents with detailed information about the NittyMail project structure, architecture, development workflow, and conventions. The project consists of a CLI application and supporting gem for email synchronization and analysis.

## 1. Project Overview & Architecture

NittyMail is a Ruby-based system for synchronizing Gmail/IMAP accounts to local SQLite databases and providing various email analysis tools.

### Project Structure
```
nittymail/
├── cli/                    # Main CLI application
│   ├── commands/          # Thor-based CLI commands
│   │   ├── mailbox.rb     # Email download/archive commands
│   │   └── db/            # Database/MCP server commands
│   │       └── mcp.rb
│   ├── models/            # ActiveRecord models
│   │   └── email.rb
│   ├── utils/             # CLI-specific utilities
│   │   ├── db.rb          # Database connection helpers
│   │   └── utils.rb       # General CLI utilities
│   ├── spec/              # CLI-specific tests
│   ├── .claude/           # AI agent configurations
│   │   ├── agents/        # Specialized agent definitions
│   │   └── commands/      # Agent command templates
│   ├── docker-compose.yml # Docker services for CLI
│   ├── cli.rb             # Main CLI entry point
│   └── AGENTS.md          # CLI-specific agent guide
├── gem/                   # NittyMail Ruby gem
│   ├── lib/nitty_mail/    # Core gem code
│   │   ├── mailbox.rb     # IMAP operations
│   │   ├── enricher.rb    # Email parsing/enrichment
│   │   ├── settings.rb    # Configuration
│   │   ├── utils.rb       # Shared utilities
│   │   └── errors.rb      # Custom exceptions
│   ├── spec/              # Gem tests
│   ├── nitty_mail.gemspec # Gem specification
│   └── AGENTS.md          # Gem-specific agent guide
├── docs/                  # Documentation
├── archives/              # Gitignored email archives
└── AGENTS.md              # This file - main agent guide
```

### Core Technologies
*   **Language/Runtime**: Ruby 3.4.4
*   **Execution**: Docker-only workflow (no local Ruby required)
*   **Database**: SQLite with ActiveRecord (WAL journaling, optimized pragmas)
*   **CLI Framework**: Thor for command-line interface
*   **IMAP Library**: `mail` gem for Gmail/IMAP communication

*   **Testing**: RSpec with `rspec-given` for BDD-style tests
*   **Linting**: StandardRB and RuboCop for code quality
*   **Progress**: `ruby-progressbar` for CLI feedback

## 2. Architecture & Key Components

### CLI Application (`cli/`)

The main user interface built with Thor. Key components:

#### Commands Structure
- **`mailbox`**: Email operations (download, archive, list)
  - `mailbox download`: Sync emails to SQLite database
  - `mailbox archive`: Save raw .eml files
  - `mailbox list`: List available IMAP mailboxes
- **`db`**: Database operations
  - `db mcp`: Start MCP server for AI agent access

#### Database Layer
- **Model**: `cli/models/email.rb` - ActiveRecord model for emails table
- **Connection**: `cli/utils/db.rb` - SQLite connection with optimized pragmas
- **Schema**: `cli/db/migrate/001_create_emails.rb` - Database migrations

#### Processing Mode
- **Single-Process Mode**: Direct IMAP fetch → parse → SQLite upsert
- Simple, no external dependencies

### NittyMail Gem (`gem/`)

Core library providing IMAP operations and email processing:

#### Key Modules
- **`NittyMail::Mailbox`**: IMAP client operations
- **`NittyMail::Enricher`**: Email parsing and metadata extraction
- **`NittyMail::Settings`**: Configuration management
- **`NittyMail::Utils`**: Shared utility functions

#### Integration Points
- CLI uses gem for IMAP operations
- Gem provides low-level email processing
- Clean separation: CLI handles UI, gem handles core logic

### Data Flow

#### Email Download Process
1. **Preflight**: Discover mailbox UIDVALIDITY and missing UIDs
2. **Fetch**: Download raw RFC822 messages in batches
3. **Parse**: Extract metadata (subject, from, date, etc.)
4. **Store**: Upsert to SQLite with conflict resolution
5. **Progress**: Real-time progress bars and counters

#### Archive Process
1. **Preflight**: Same UID discovery as download
2. **Fetch**: Download raw messages
3. **Save**: Write `.eml` files to `cli/archives/`
4. **Resume**: Skip existing files on re-run

#### MCP Server Process
1. **Connect**: Open SQLite database read-only
2. **Listen**: Accept MCP tool calls over stdio
3. **Query**: Execute safe SQL queries with limits
4. **Respond**: Return structured JSON results

## 3. Development Workflow & Commands

### Environment Setup

1. **Configure CLI Environment**:
   ```bash
   cd cli
   cp .env.sample .env
   # Edit .env to set:
   # - NITTYMAIL_IMAP_ADDRESS=your@email.com
   # - NITTYMAIL_IMAP_PASSWORD=your-app-password
   # - NITTYMAIL_SQLITE_DB=./data/emails.sqlite3 (optional)
   ```

2. **Install Dependencies** (automatic on first run):
   ```bash
   # CLI dependencies (from cli/ directory)
   docker compose run --rm cli bundle install

   # Gem dependencies (from gem/ directory)
   cd gem && bundle install
   ```

### Development Commands

#### CLI Development (from project root)
```bash
# Run CLI commands
docker compose run --rm ruby bundle exec ruby cli/cli.rb [command]

# Interactive shell
docker compose run --rm ruby bash

# View CLI help
docker compose run --rm ruby bundle exec ruby cli/cli.rb --help
```

#### Gem Development (from gem/ directory)
```bash
# Run gem console
bundle exec bin/console

# Build gem
bundle exec rake build

# Install locally
bundle exec rake install
```

### Testing Procedures

#### CLI Tests (from project root)
```bash
# Full CLI test suite
docker compose run --rm ruby bundle exec rspec -fd -b cli/spec/

# Single CLI test file
docker compose run --rm ruby bundle exec rspec -fd -b cli/spec/cli/utils_spec.rb

# Run from cli/ directory
cd cli && docker compose run --rm cli bundle exec rspec -fd -b spec/cli/utils_spec.rb
```

#### Gem Tests (from gem/ directory)
```bash
# Full gem test suite
bundle exec rspec -fd -b

# Single gem test file
bundle exec rspec -fd -b spec/NittyMail/utils_spec.rb

# From project root
docker compose run --rm ruby bundle exec rspec -fd -b gem/spec/
```

#### Test Guidelines
- **Framework**: RSpec with `rspec-given` for BDD-style tests
- **CLI Tests**: Focus on integration, command behavior
- **Gem Tests**: Unit tests for core IMAP/email processing logic
- **Mocking**: Use real IMAP connections sparingly; prefer VCR for integration tests
- **Patterns**: Given/When/Then for readability, descriptive test names

### Linting & Code Quality

#### CLI Linting (from cli/ directory)
```bash
# Auto-fix and lint
docker compose run --rm cli bundle exec standardrb --fix
docker compose run --rm cli bundle exec rubocop -A

# Check only
docker compose run --rm cli bundle exec standardrb
docker compose run --rm cli bundle exec rubocop
```

#### Gem Linting (from gem/ directory)
```bash
# Auto-fix and lint
bundle exec standardrb --fix
bundle exec rubocop -A

# Check only
bundle exec standardrb
bundle exec rubocop
```

### Git Workflow & Committing

#### Commit Message Format
Use Conventional Commits with heredoc format:
```bash
git commit -F - << 'EOF'
feat(cli): Add new mailbox command

Why:
- Users need to archive emails locally
- Current download only supports database storage

What:
- Add mailbox archive subcommand
- Save raw .eml files to cli/archives/
- Support resumable downloads
EOF
```

#### Commit Guidelines
- **Format**: `type(scope): subject` (e.g., `feat(cli)`, `fix(gem)`, `docs(agents)`)
- **Heredoc**: Always use heredoc format to satisfy git hooks
- **No Co-authors**: Do not include `Co-Authored-By` lines
- **No AI mentions**: Do not include generated-by lines
- **Atomic**: Keep commits focused on single changes

#### Working Directory
- **File Operations**: Always work from project root
- **Git Commands**: Run from project root
- **CLI Development**: May need to work in `cli/` subdirectory
- **Gem Development**: Work in `gem/` subdirectory

## 5. AI Agent Guidelines & Conventions

### Code Style Guidelines

#### Ruby Style
- **Hash Shorthand**: Use `{key:}` when key matches variable name
- **String Interpolation**: Prefer `"#{var}"` over `'#{var}'` for consistency
- **Method Names**: `snake_case` for methods/variables, `CamelCase` for classes
- **Constants**: `UPPER_SNAKE_CASE` for constants
- **Indentation**: 2 spaces, no tabs
- **Line Length**: Keep lines readable; break long lines appropriately

#### CLI-Specific Conventions
- **Thor Commands**: Use `method_option` for CLI flags with clear descriptions
- **Error Handling**: Fail fast with clear user messages for setup issues
- **Progress Bars**: Use `ruby-progressbar` for long-running operations
- **Logging**: Use appropriate log levels; prefer structured output

#### Testing Conventions
- **RSpec-Given**: Use Given/When/Then/And for BDD-style tests
- **Test Names**: Descriptive, explain what behavior is being tested
- **Mocking**: Mock external services (IMAP) to keep tests fast
- **Fixtures**: Use realistic test data that matches production scenarios

### Exception Handling Guidelines

#### General Rules
- **Specific Rescue**: Always rescue specific exception classes, never bare `rescue`
- **No Modifiers**: Avoid `rescue` modifiers; use explicit `begin/rescue` blocks
- **Fail Fast**: Never hide initialization failures that leave system unusable
- **Log Context**: When rescuing, log actionable error context and user impact
- **Surface Failures**: Return error indicators or raise with clear messages

#### CLI-Specific Handling
```ruby
# Good: Specific rescue with context
begin
  imap_operation
rescue Net::IMAP::NoResponseError => e
  logger.error "IMAP authentication failed for #{address}: #{e.message}"
  raise ArgumentError, "Invalid IMAP credentials. Check address/password."
end

# Bad: Bare rescue
begin
  risky_operation
rescue => e  # Too broad, hides real issues
  puts "Something went wrong"
end
```

### Database Guidelines

#### SQLite Optimization
- **WAL Mode**: Enabled by default for concurrent reads/writes
- **Pragmas**: Optimized via `cli/utils/db.rb` (synchronous=NORMAL, temp_store=MEMORY)
- **Indexing**: Composite unique index on `(address, mailbox, uidvalidity, uid)`
- **Connection**: Single connection per CLI run; reuse for all operations

#### Migration Practices
- **Version**: Use `ActiveRecord::Migration[8.0]` for current AR version
- **Safety**: Prefer additive changes; document destructive operations
- **Naming**: `001_create_emails.rb` with incremental numeric prefixes
- **Reversible**: Provide `up`/`down` methods for all migrations



### Security Considerations

#### IMAP Credentials
- **App Passwords**: Required for Gmail 2FA accounts
- **Environment**: Store in `.env` files, never in code
- **Validation**: Verify credentials before long-running operations

#### Database Security
- **Read-Only**: MCP server provides read-only database access
- **SQL Injection**: Parameter binding for all queries
- **Limits**: Row limits and query timeouts to prevent abuse
- **Sanitization**: LIKE pattern cleaning to prevent wildcard abuse

### File Organization

#### CLI Structure
- **Commands**: `cli/commands/` - Thor command classes
- **Models**: `cli/models/` - ActiveRecord models
- **Utils**: `cli/utils/` - Shared utilities and database helpers
- **Specs**: `cli/spec/` - CLI-specific tests
- **Data**: `cli/data/` - SQLite databases (gitignored)
- **Archives**: `cli/archives/` - Raw email files (gitignored)

#### Gem Structure
- **Core**: `gem/lib/nitty_mail/` - Main library code
- **Specs**: `gem/spec/` - Unit tests for gem components
- **Bin**: `gem/bin/` - Development utilities (console, setup)

### Development Environment

#### Docker Workflow
- **No Local Ruby**: All development happens in Docker containers
- **Volume Mounts**: Project root mounted for live development
- **Bundle Path**: Persisted in `.bundle/` to avoid re-installation
- **Environment**: `.env` files for configuration

#### Git Hygiene
- **Ignore Patterns**: SQLite files, email archives, bundle cache
- **Hooks**: Commit message validation via `.githooks/`
- **Conventional Commits**: Enforced by git hooks
- **Working Directory**: Always commit from project root

### Testing Best Practices

#### Test Organization
- **CLI Tests**: Integration-focused, test command behavior
- **Gem Tests**: Unit-focused, test core IMAP and email processing logic
- **Mocking Strategy**: Mock external services; use VCR for IMAP integration tests
- **Test Data**: Use realistic fixtures that match production email structures

#### Common Test Patterns
```ruby
# CLI Integration Test
describe "mailbox download" do
  Given(:settings) { NittyMail::Settings.new(imap_address: "test@example.com") }
  Given(:mailbox_client) { instance_double(NittyMail::Mailbox) }

  When { download_command.run }

  Then { expect(database).to have_emails }
end

# Gem Unit Test
describe NittyMail::Enricher do
  Given(:raw_email) { File.read("spec/fixtures/raw_email.txt") }

  When(:result) { described_class.enrich(raw_email) }

  Then { expect(result[:subject]).to eq("Test Email") }
  Then { expect(result[:from_email]).to eq("sender@example.com") }
end
```

### Troubleshooting Guide

#### Common Issues & Solutions

**"Could not find X in locally installed gems"**
```bash
# From project root
docker compose run --rm ruby bundle install

# Or from cli directory
cd cli && docker compose run --rm cli bundle install
```

**"no configuration file provided: not found"**
- Run Docker commands from project root, not cli/ subdirectory
- Ensure docker-compose.yml exists in the directory you're running from

**IMAP Connection Issues**
- Verify Gmail IMAP is enabled in account settings
- Use app passwords for 2FA accounts
- Check network connectivity and firewall rules

**Database Lock Errors**
- Close other SQLite connections
- Check for long-running processes
- Use WAL mode (enabled by default)



**Test Failures**
- Ensure test database is clean between runs
- Check for missing VCR cassettes
- Verify environment variables are set correctly

### Quick Reference

#### Essential Commands
```bash
# Development setup
cd cli && cp .env.sample .env  # Configure IMAP credentials

# Run tests
docker compose run --rm ruby bundle exec rspec -fd -b cli/spec/

# Download emails
docker compose run --rm ruby bundle exec ruby cli/cli.rb mailbox download --mailbox INBOX

# Start MCP server
docker compose run --rm ruby bundle exec ruby cli/cli.rb db mcp --database ./emails.sqlite3

# Lint code
docker compose run --rm ruby bundle exec standardrb --fix
```

#### Key Files
- `cli/cli.rb` - Main CLI entry point
- `cli/commands/mailbox.rb` - Email operations
- `cli/models/email.rb` - Database model
- `cli/utils/db.rb` - Database connection
- `gem/lib/nitty_mail/` - Core library modules
- `AGENTS.md` - This guide (also `cli/AGENTS.md`, `gem/AGENTS.md`)

#### Environment Variables
- `NITTYMAIL_IMAP_ADDRESS` - Gmail address
- `NITTYMAIL_IMAP_PASSWORD` - Gmail password/app password
- `NITTYMAIL_SQLITE_DB` - SQLite database path
- `NITTYMAIL_QUIET` - Reduce logging (MCP server)

This guide should provide AI agents with comprehensive knowledge of the NittyMail project structure, development workflow, and best practices. Refer to component-specific AGENTS.md files (`cli/AGENTS.md`, `gem/AGENTS.md`) for additional details.

## 4. CLI Commands Reference

All commands are run from project root using Docker. The CLI uses subcommands under `mailbox` and `db`.

### Mailbox Commands

#### `mailbox list` - List IMAP Mailboxes
```bash
docker compose run --rm ruby bundle exec ruby cli/cli.rb mailbox list [options]
```
**Options:**
- `-a, --address EMAIL`: IMAP account email (or `NITTYMAIL_IMAP_ADDRESS`)
- `-p, --password PASS`: IMAP password (or `NITTYMAIL_IMAP_PASSWORD`)

#### `mailbox download` - Sync Emails to SQLite
```bash
docker compose run --rm ruby bundle exec ruby cli/cli.rb mailbox download [options]
```
**Key Options:**
- `--mailbox NAME`: Mailbox to download (default: INBOX)
- `--database PATH`: SQLite database path (default: `cli/data/[ADDRESS].sqlite3`)
- `--max-fetch-size N`: IMAP fetch batch size (default: 200)
- `--batch-size N`: DB upsert batch size (default: 100)
- `--strict`: Fail-fast on errors instead of skipping
- `--recreate`: Drop and re-download current mailbox generation
- `--purge-uidvalidity N`: Delete specific UIDVALIDITY generation
- `--yes`: Skip confirmation prompts

#### `mailbox archive` - Save Raw Email Files
```bash
docker compose run --rm ruby bundle exec ruby cli/cli.rb mailbox archive [options]
```
**Key Options:**
- `--mailbox NAME`: Mailbox to archive
- `--output PATH`: Output directory (default: `cli/archives/`)
- `--max-fetch-size N`: IMAP fetch batch size
- `--strict`: Fail-fast on errors
- `--only-preflight`: Only list UIDs to be archived (no files created)

### Database Commands

#### `db mcp` - Start MCP Server
```bash
docker compose run --rm ruby bundle exec ruby cli/cli.rb db mcp [options]
```
**Key Options:**
- `--database PATH`: SQLite database path
- `--address EMAIL`: Email address context
- `--max-limit N`: Max rows per query (default: 1000)
- `--quiet`: Reduce logging

**Available MCP Tools:**
- Email retrieval: `get_email_full`, `filter_emails`, `list_earliest_emails`
- Analytics: `get_email_stats`, `get_top_senders`, `get_mailbox_stats`
- Search: `search_email_headers`, `get_emails_by_keywords`
- Advanced: `execute_sql_query`, `get_emails_by_size_range`

### Common Options (All Commands)
- `--help`: Show command help
- Environment variables override flags:
  - `NITTYMAIL_IMAP_ADDRESS`
  - `NITTYMAIL_IMAP_PASSWORD`
  - `NITTYMAIL_SQLITE_DB`

### Command Examples
```bash
# List mailboxes
docker compose run --rm ruby bundle exec ruby cli/cli.rb mailbox list

# Download Gmail inbox
docker compose run --rm ruby bundle exec ruby cli/cli.rb mailbox download --mailbox INBOX

# Download with custom database
docker compose run --rm ruby bundle exec ruby cli/cli.rb mailbox download \
  --mailbox "[Gmail]/All Mail" \
  --database ./my-emails.sqlite3

# Archive sent mail
docker compose run --rm ruby bundle exec ruby cli/cli.rb mailbox archive \
  --mailbox "[Gmail]/Sent Mail"

# List UIDs that would be archived (no files created)
docker compose run --rm ruby bundle exec ruby cli/cli.rb mailbox archive \
  --mailbox INBOX --only-preflight

# Start MCP server
docker compose run --rm ruby bundle exec ruby cli/cli.rb db mcp \
  --database ./emails.sqlite3
```
