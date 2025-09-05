# Spec Requirements Document

> Spec: cli-db-mcp-server
> Created: 2025-09-05

## Overview

Add a new `cli db mcp` command that runs a Model Context Protocol (MCP) server over stdio, exposing read-only email database tools for local agents. The server provides structured access to email data (filters, stats, analytics) and a secure SQL read interface, with semantic search stubbed initially. This server has no IMAP connections; it operates solely against the local SQLite database.

## User Stories

### Query email data via local agent

As a developer using an MCP-capable AI tool, I want to connect to a local stdio MCP server that can answer structured questions about my email (lists, counts, stats, trends) so that I can build automations and analyses without granting cloud access to my inbox.

Detailed workflow:
- Launch `docker compose run --rm cli ./cli.rb db mcp`.
- The agent connects over stdio (JSON-RPC / MCP handshake) and lists tools.
- The agent calls tools like `db.filter_emails`, `db.get_top_senders`, or `db.execute_sql_query` and receives structured JSON results.
- Semantic search (`db.search_emails`) returns a predictable stub response until embeddings are implemented in this CLI.

### Secure exploratory SQL for power users

As a power user, I want a read-only SQL tool that blocks writes and unsafe pragmas so that I can explore data safely and quickly iterate on ad-hoc queries without risking database corruption.

Detailed workflow:
- Call `db.execute_sql_query` with a SELECT/WITH query.
- Server validates query class, injects a LIMIT when missing, executes, and returns rows with capped size and row count.

## Spec Scope

1. **New MCP server command** - `cli db mcp` runs an MCP server over stdio with lifecycle: initialize, tools/list, tools/call, shutdown.
   - File path: implement in `commands/db/mcp.rb` and wire into `cli.rb`.
2. **Tools exposure** - Implement the following tools: db.list_earliest_emails, db.get_email_full, db.filter_emails, db.search_emails (stub), db.count_emails, db.get_email_stats, db.get_top_senders, db.get_top_domains, db.get_largest_emails, db.get_mailbox_stats, db.get_emails_by_date_range, db.get_emails_with_attachments, db.get_email_thread, db.get_email_activity_heatmap, db.get_response_time_stats, db.get_email_frequency_by_sender, db.get_seasonal_trends, db.get_emails_by_size_range, db.get_duplicate_emails, db.search_email_headers, db.get_emails_by_keywords, db.execute_sql_query.
3. **Result formatting** - Each tool returns an MCP `tools/call` result with a single `{type: "text", text: <json>}` item containing JSON-serialized data as specified.
4. **Database access** - Use the existing CLI SQLite (ActiveRecord) connection helper and models; queries are read-only and respect existing schema.
5. **Security** - Enforce read-only SQL validation and parameterized queries; cap limits and result sizes; sanitize LIKE patterns.
6. **Observability** - Minimal structured logging to stderr for server lifecycle and tool errors (no sensitive data).
7. **Time fields** - Return both `internaldate` (ISO8601) and `internaldate_epoch` (indexed) in results; use `internaldate_epoch` for ordering and range filters.
8. **IMAP Integration (out of scope for this command)** - This command does not initiate any IMAP connections. For sync/downloader flows elsewhere in the CLI, leverage the local gem `nitty_mail` (path: `../gem`). If gaps arise, surface suggestions for owner review on a case-by-case basis before adding features.
9. **Defaults & Env Vars** - Use sane defaults with environment overrides:
   - `--database`: defaults to `ENV["NITTYMAIL_SQLITE_DB"]` if set; else `utils/db.rb` derived path (`cli/data/<ADDRESS>.sqlite3`).
   - `--address`: defaults to `ENV["NITTYMAIL_IMAP_ADDRESS"]` when not provided.
   - `--max-limit`: defaults to 1000; allow override via `ENV["NITTYMAIL_MCP_MAX_LIMIT"]` if present.
   - `--quiet`: defaults to false; allow `ENV["NITTYMAIL_QUIET"]` to toggle if desired.
   - Maintain `.env.sample`: add any newly used env vars if missing (e.g., `NITTYMAIL_SQLITE_DB`, `NITTYMAIL_MCP_MAX_LIMIT`, `NITTYMAIL_QUIET`).
10. **Documentation Alignment** - Update CLI documentation to reflect this feature: command help, README usage, environment variables, tool list with parameters/returns, and notes on stubbed semantic search.

## Out of Scope

- Implementing embeddings-backed semantic search in the CLI (tool is stubbed initially).
- IMAP sync, enrich, embed, or any data mutations.
- Non-stdio transports (e.g., sockets, HTTP) and authentication layers for the MCP server.
- Agent-facing UI/visualizations; only structured data is returned.

## Expected Deliverable

1. `cli db mcp` command launches a functioning MCP stdio server exposing the listed tools; returns valid MCP responses and passes basic manual tests with an MCP client.
2. All tools perform read-only operations with enforced safety checks, parameter validation, and deterministic JSON result shapes according to this spec; semantic search returns a stubbed but valid response.
3. Documentation updated and consistent with behavior: README, command help (`--help`), examples, and env var references.
