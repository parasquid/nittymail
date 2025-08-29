# GEMINI.md: NittyMail Project Guide

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
4.  **Embed (Optional)**: If an `OLLAMA_HOST` is configured, it will generate vector embeddings for the subject and body of new messages during the sync.

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

### Linting & Testing (Run Before Every Commit)

1.  **Lint Code**: This script applies safe auto-fixes and verifies against both StandardRB and RuboCop.
    ```bash
    ./bin/lint
    ```

2.  **Run Tests**: Ensure all RSpec tests pass.
    ```bash
    docker compose run --rm ruby bundle exec rspec
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

## 4. CLI Commands Reference

All commands are invoked via `docker compose run --rm ruby ../cli.rb <command>`.

### `sync`

Synchronizes Gmail messages to the local database.

*   **Command**:
    ```bash
    docker compose run --rm ruby ../cli.rb sync [options]
    ```
*   **Key Options**:
    *   `--threads <n>`: Number of parallel threads for fetching messages.
    *   `--ignore-mailboxes "Spam,Trash"`: Comma-separated list of mailboxes to skip.
    *   `--ollama-host <url>`: URL of the Ollama server to enable embedding during sync.
    *   `--auto-confirm`: Skip the interactive confirmation prompt.

### `query`

Asks a natural language question about your email.

*   **Command**:
    ```bash
    docker compose run --rm ruby ../cli.rb query "<your question>"
    ```
*   **Key Options**:
    *   `--model <name>`: The chat model to use (default: `qwen2.5:7b-instruct`).
    *   `--limit <n>`: The default number of results to return.
    *   `--debug`: Show the requests and responses to/from Ollama.

### `embed`

Backfills vector embeddings for existing emails.

*   **Command**:
    ```bash
    docker compose run --rm ruby ../cli.rb embed [options]
    ```
*   **Key Options**:
    *   `--model <name>`: The embedding model to use (default: `mxbai-embed-large`).
    *   `--limit <n>`: Limit the number of emails to process.
    *   `--threads <n>`: Number of parallel threads for making requests to Ollama.
