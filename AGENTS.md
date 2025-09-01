# Main Project Guide: core/README.md

Canonical user-facing guide is `core/README.md`.

This document provides a comprehensive overview of the NittyMail project, its architecture, and the primary commands and conventions required for development. For a strict set of rules for AI agent behavior, refer to `AGENTS.md`.

## 1. Project Overview & Core Technologies

NittyMail is a set of command-line tools written in Ruby to synchronize a Gmail account to a local SQLite database and perform queries against it.

*   **Language/Runtime**: Ruby 3.4, executed exclusively via Docker.
*   **Core Libraries**:
    *   `thor`: For building the CLI interface.
    *   `sequel`: As the ORM for the SQLite database.
    *   `mail`: For all IMAP communication with Gmail.
    *   `sqlite-vec`: To enable vector search capabilities within SQLite.
*   **Natural Language Processing**: Uses a local LLM (e.g., `qwen2.5:7b-instruct`) via an Ollama server for parsing natural language queries.
*   **Development Tools**:
    *   `rspec`: For testing.
    *   `standardrb` & `rubocop`: For linting and code style enforcement.

## 2. Architecture & Key Concepts

### Sync Process (`sync`)

The sync process is the core feature. It connects to Gmail via IMAP and saves messages to the local SQLite DB.
1.  **Preflight**: For each mailbox, it first determines the `UIDVALIDITY` and calculates the difference between UIDs on the server and UIDs in the local database to identify exactly which messages to fetch.
2.  **Fetch**: It uses a multi-threaded approach to fetch the missing messages in batches.
3.  **Store**: Messages are parsed and stored in the `email` table.
4.  **Embeddings**: Sync downloads mail only. Use `./cli.rb embed` to generate vector embeddings after sync (requires `OLLAMA_HOST`).

### Query Process (`query`)

The query command translates natural language questions into SQL queries.
1.  **Tool-Based LLM**: It sends the user's prompt to an Ollama model that has been given a set of tools (functions) for searching the database (e.g., by date, sender, or vector similarity).
2.  **SQL Generation**: The LLM decides which tool to use and generates the appropriate parameters, which the application then uses to construct and execute a SQL query.
3.  **No Fallback**: This process requires a functioning Ollama instance with a tool-capable model. There is no non-LLM fallback.

### Vector Embeddings (`embed`)

Vector embeddings allow for semantic search (i.e., finding emails "about" a certain topic).
*   **Storage**: Embeddings are stored as `BLOB` data in a virtual table (`email_vec`) powered by the `sqlite-vec` extension.
*   **Default Model**: The default embedding model is `mxbai-embed-large` (1024 dimensions).
*   **Backfilling**: The `embed` command can be used to generate embeddings for emails that were synced before the embedding feature was enabled.

## 3. Development Workflow & Commands

**MANDATORY**: All commands must be run from the project root via Docker Compose.

### Setup

1.  **Configure Environment**: Create the environment file from the sample.
    ```bash
    cp core/config/.env.sample core/config/.env
    ```
    Then, **you must edit `core/config/.env`** to set your `ADDRESS`, `PASSWORD`, and `DATABASE` path.

2.  **Install Dependencies**:
    ```bash
    docker compose run --rm ruby bundle install
    ```

### Linting & Testing (Ruby changes only)

Only run StandardRB/RuboCop/RSpec when Ruby code changes or behavior changes.

- Skip for non-Ruby-only changes (e.g., Markdown docs, .env samples, JSON, YAML, text files).
- Run for any `.rb` edits or behavior-affecting changes.

1.  **Lint Ruby** (when applicable): applies safe auto-fixes and verifies StandardRB and RuboCop.
    ```bash
    ./bin/lint
    ```

2.  **Run RSpec** (when applicable): Canonical command — do not improvise other invocations.
    ```bash
    # Always run from the repo root; Docker working_dir is /app/core
    docker compose run --rm ruby bundle exec rspec -fd -b

    # Run a single file (example):
    docker compose run --rm ruby bundle exec rspec -fd -b spec/mcp_server_spec.rb
    ```

    Notes:
    - Do not use host Ruby. Always go through Docker Compose as above.
    - Keep `bundle exec` and the `-fd -b` flags (formatter + backtraces) for consistent, debuggable output.
    - MCP specs manage their own environment; you should not need to export `DATABASE` to run them.

3.  **RSpec style (AI agents):** Prefer `rspec-given` for new specs.
    - Use Given/When/Then/And macros from `rspec-given` for readability.
    - Require `rspec/given` via `spec_helper` (already configured).
    - Existing non-Given specs may remain as-is; do not rewrite unless necessary.

#### Stubbing reporter events in tests

Use a simple collecting reporter that records every `event(type, payload)` call. Example:

```ruby
class CollectingReporter < NittyMail::Reporting::BaseReporter
  attr_reader :events
  def initialize(*)
    super
    @events = []
  end
  def event(type, payload = {})
    @events << [type.to_sym, payload]
    super
  end
end

Given(:rep) { CollectingReporter.new }
When  { NittyMail::Enrich.perform(database_path: db_path, quiet: true, reporter: rep) }
Then  { rep.events.map(&:first).include?(:enrich_finished) }
```

### Committing

1.  **Format**: Use Conventional Commits (`type(scope): subject`).
2.  **Multi-line Messages**: **MUST** use the heredoc format to prevent git hook failures:
    ```bash
    git commit -F - << 'EOF'
    feat(sync): Add a new feature

    Why:
    - Motivation for the changes.

    What:
    - Description of what was changed.
    EOF
    ```
3.  **Co-Author Lines**: Do **NOT** include co-author lines (e.g., `Co-Authored-By: Claude <noreply@anthropic.com>`) or generated lines (e.g., `🤖 Generated with [Claude Code]`) in commit messages.

### Ruby Style Guidelines (AI Agents)

- **Hash Shorthand**: Use Ruby hash shorthand syntax when the key matches the variable name (e.g., `{foo:}` instead of `{foo: foo}`).

### Development Workflow (AI Agents)

- **Working Directory**: Always execute file operations from the project root directory, not from the `core/` subdirectory. Commands like `./bin/lint`, `git add`, `git commit` should be run from the parent directory where these tools are located.

### Exception Handling (AI Agents)

- Do not swallow exceptions unless the maintainer explicitly requests it or there is a compelling, documented reason.
- Prefer rescuing specific error classes; avoid `rescue => e` without re‑raise.
- Do not use rescue modifiers (e.g., `call rescue nil`). Use explicit `begin/rescue` blocks and either re‑raise or handle with clear remediation.
- If a rescue is necessary (e.g., to continue a batch process), log the error with actionable context and surface failures (e.g., via return values or counters). Add a short justification in the PR/commit body.
- Never hide initialization failures that would leave the process in an unusable state. Fail fast with a clear, user‑facing error message.

### Event Schema (Reference for Agents)

Library code reports progress exclusively via a single hook: `reporter.event(type, payload)`. The CLI adapts these into progress bars/logs. When writing code or tests, use these events and payloads.

Sync Events

| Event | Key payload keys |
|---|---|
| `preflight_started` | `total_mailboxes`, `threads` |
| `preflight_mailbox` | `mailbox`, `uidvalidity`, `to_fetch`, `to_prune`, `server_size`, `db_size`, `uids_preview` |
| `preflight_finished` | `mailboxes` |
| `mailbox_started` | `mailbox`, `uidvalidity`, `total`, `threads`, `thread_word` |
| `mailbox_skipped` | `mailbox`, `reason` |
| `sync_worker_started/stopped` | `mailbox`, `thread` |
| `sync_writer_started/stopped` | `mailbox`, `thread` |
| `sync_fetch_started/finished` | `mailbox`, `batch_size` / `count` |
| `sync_message_processed` | `mailbox`, `uid` |
| `prune_candidates_present` | `mailbox`, `uidvalidity`, `candidates` |
| `pruned_missing` | `mailbox`, `uidvalidity`, `pruned` |
| `purge_old_validity` | `mailbox`, `uidvalidity`, `purged` |
| `purge_skipped` | `mailbox`, `uidvalidity` |
| `mailbox_summary` | `mailbox`, `uidvalidity`, `total`, `prune_candidates`, `pruned`, `purged`, `processed`, `errors`, `result` |
| `mailbox_finished` | `mailbox`, `uidvalidity`, `processed`, `result` |

Enrich Events

| Event | Key payload keys |
|---|---|
| `enrich_started` | `total`, `address` |
| `enrich_field_error` | `id`, `field`, `error`, `message` |
| `enrich_error` | `id`, `error`, `message` |
| `enrich_progress` | `current`, `total`, `delta` |
| `enrich_interrupted` | `processed`, `total`, `errors` |
| `enrich_finished` | `processed`, `total`, `errors` |

Embed Events

| Event | Key payload keys |
|---|---|
| `embed_scan_started` | `total_emails`, `address`, `model`, `dimension`, `host` |
| `embed_started` | `estimated_jobs` |
| `embed_jobs_enqueued` | `count` |
| `embed_worker_started/stopped` | `thread` |
| `embed_writer_started/stopped` | `thread` |
| `embed_status` | `job_queue`, `write_queue` |
| `embed_error` | `email_id`, `error`, `message` |
| `embed_db_error` | `email_id`, `error`, `message` |
| `embed_batch_written` | `count` |
| `embed_interrupted` | `processed`, `total`, `errors`, `job_queue`, `write_queue` |
| `embed_finished` | `processed`, `total`, `errors` |
| `db_checkpoint_complete` | `mode` |

### IMAP Cassettes (Integration Guidance)

- Record vs replay:
  - On the first run there is no cassette; the replay example will fail. Set `INTEGRATION_RECORD=1` to record, then re-run to replay offline.
  - Use `ONLY_MAILBOXES` or the Rake task argument to limit recording to a small mailbox (e.g., `INBOX`).
- Expected logs:
  - Filtering logs like `including 1 mailbox(es) via --only: INBOX (was 8)` and `skipping 7 mailbox(es) due to --only` are normal and indicate the include filter is applied.
- Credentials:
  - Tests run under Docker and load `core/config/.env` (via `dotenv/load`). Ensure `ADDRESS`, `PASSWORD`, `DATABASE` are set.
  - Gmail App Password is required if 2FA is enabled; IMAP must be enabled in Gmail settings.

## 4. CLI Commands Reference

All commands are invoked via `docker compose run --rm ruby ./cli.rb <command>`.

### `sync`

Synchronizes Gmail messages to the local database.

*   **Command**:
    ```bash
    docker compose run --rm ruby ./cli.rb sync [options]
    ```
*   **Key Options**:
    *   `--address <email>`: Gmail address to sync.
    *   `--password <pass>`: Gmail password or app password.
    *   `--database <path>`: SQLite database file path.
    *   `--threads <n>`: Number of parallel threads for fetching messages.
    *   `--mailbox_threads <n>`: Threads for mailbox preflight (UID discovery).
    *   `--auto-confirm`: Skip the interactive confirmation prompt.
    *   `--purge_old_validity`: Purge rows from older UIDVALIDITY generations after successful sync.
    *   `--fetch_batch_size <n>`: UID FETCH batch size.
    *   `--ignore-mailboxes "Spam,Trash"`: Comma-separated list of mailboxes to skip.
    *   `--only <mailboxes>`: Comma-separated list of mailboxes to include (others are skipped).
    *   `--strict_errors`: Raise exceptions instead of swallowing/logging certain recoverable errors.
    *   `--retry_attempts <n>`: Max IMAP retry attempts per batch.
    *   `--prune_missing`: Delete DB rows for UIDs missing on server.
    *   `--quiet`: Quiet mode.
    *   `--sqlite_wal`: Enable SQLite WAL journaling.
    *   (Embeddings are not generated by sync; use `./cli.rb embed`.)

### `query`

Asks a natural language question about your email.

*   **Command**:
    ```bash
    docker compose run --rm ruby ./cli.rb query "<your question>"
    ```
*   **Key Options**:
    *   `--database <path>`: SQLite database file path.
    *   `--address <email>`: Gmail address context.
    *   `--ollama_host <url>`: Ollama base URL for chat.
    *   `--model <name>`: The chat model to use (default: `qwen2.5:7b-instruct`).
    *   `--limit <n>`: The default number of results to return.
    *   `--quiet`: Reduce log output.
    *   `--debug`: Show the requests and responses to/from Ollama.

### `embed`

Backfills vector embeddings for existing emails.

*   **Command**:
    ```bash
    docker compose run --rm ruby ./cli.rb embed [options]
    ```
*   **Key Options**:
    *   `--database <path>`: SQLite database file path.
    *   `--address <email>`: Optional filter: only embed rows for this Gmail address.
    *   `--item_types <types>`: Comma-separated fields to embed (subject,body).
    *   `--limit <n>`: Limit number of emails to process.
    *   `--offset <n>`: Offset for pagination.
    *   `--ollama_host <url>`: Ollama base URL for embeddings.
    *   `--model <name>`: The embedding model to use (default: `mxbai-embed-large`).
    *   `--dimension <n>`: Embedding dimension.
    *   `--threads <n>`: Number of embedding worker threads.
    *   `--retry_attempts <n>`: Max embedding retry attempts.
    *   `--quiet`: Reduce log output.
    *   `--batch_size <n>`: Emails-to-queue window during embed.
    *   `--regenerate`: Regenerate ALL embeddings for the specified model.
    *   `--no_search_prompt`: Disable search prompt optimization.

### `enrich`

Extract envelope/body metadata from stored raw messages and persist to the email table.

*   **Command**:
    ```bash
    docker compose run --rm ruby ./cli.rb enrich [options]
    ```
*   **Key Options**:
    *   `--database <path>`: SQLite database file path.
    *   `--address <email>`: Optional filter: only process rows for this Gmail address.
    *   `--limit <n>`: Limit number of emails to process.
    *   `--offset <n>`: Offset for pagination.
    *   `--quiet`: Reduce log output.
