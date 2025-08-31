# NittyMail MCP Server - Quick Start

**Note:** This server is designed to be run via Docker. A local Ruby installation is not required.

A standalone Model Context Protocol server that exposes all 22 NittyMail email database tools for use with Claude Desktop and other MCP clients.

## Quick Test

```bash
# Test server startup
docker compose run --rm ruby ./mcp_server.rb

# Test with a simple request  
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  docker compose run --rm ruby ./mcp_server.rb 2>/dev/null | jq '.result.tools | length'
# Should output: 22
```

## Client Setup (Summary)

Replace `/absolute/path/to/nittymail/core` with your actual path:

### Claude Desktop
Add to MCP config file (`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS):

```json
{
  "mcpServers": {
    "nittymail": {
      "command": "docker",
      "args": ["compose", "-f", "/absolute/path/to/nittymail/core/docker-compose.yml", "run", "--rm", "ruby", "./mcp_server.rb"],
      "cwd": "/absolute/path/to/nittymail/core"
    }
  }
}
```

### Gemini CLI

1.  **Install Gemini CLI:**
    ```bash
    pip install google-generativeai-cli
    ```

2.  **Add the NittyMail MCP Server:**
    Replace `/path/to/your/nittymail/core` with the absolute path to the `core` directory.

    ```bash
    gemini mcp add nittymail "docker compose run --rm ruby ./mcp_server.rb" --scope project --description "NittyMail Email Client"
    ```

3.  **Chat with your email:**
    ```bash
    gemini chat "show me my top 5 senders"
    ```


### OpenAI (via Bridge)
```bash
npm install -g @modelcontextprotocol/client-openai
mcp-openai-bridge --mcp-command "docker compose run --rm ruby ./mcp_server.rb" --mcp-cwd "/absolute/path/to/nittymail/core" --openai-key "$OPENAI_API_KEY"
```

## What You Can Ask

Once connected to Claude, Gemini, or GPT:

- "Show me my email statistics overview"
- "Who are my top senders?"
- "Find emails about meetings from last year"
- "How many emails have attachments?"
- "Show monthly email volume trends"
- "What are my email activity patterns by hour and day?"
- "Find duplicate emails in my inbox"
- "Show me the largest emails I have"
- "What are my seasonal email trends?"
- "Find emails containing keywords 'budget' and 'proposal'"
- "Run this SQL query: SELECT DISTINCT from FROM email WHERE subject LIKE '%meeting%' LIMIT 10"

## Common Tools (Cheat Sheet)

**Core Analytics:**
- `db.get_email_stats(top_limit)` – overview: totals, date range, top senders/domains
- `db.get_top_senders(limit, mailbox)` – most frequent senders
- `db.get_top_domains(limit)` – most frequent sender domains
- `db.get_largest_emails(limit, attachments, mailbox, from_domain)` – largest messages by stored size; `attachments` = any|with|without

**Filtering & Search:**
- `db.filter_emails(...)` – simple filters: from/subject contains, mailbox, date range
- `db.search_emails(query, item_types, limit)` – semantic search (requires embeddings)
- `db.get_emails_by_keywords(keywords, match_mode, limit)` – keyword search with scoring; `match_mode` = any|all
- `db.get_emails_by_size_range(size_category, limit)` – filter by size: small|medium|large|huge

**Time Analytics:**
- `db.get_email_activity_heatmap(date_from, date_to)` – hourly/daily activity patterns
- `db.get_seasonal_trends(years_back)` – monthly trends with seasonal classification
- `db.get_response_time_stats(limit)` – response times between thread emails

**Advanced:**
- `db.get_duplicate_emails(similarity_field, limit)` – find duplicates by subject/message_id
- `db.search_email_headers(header_pattern, limit)` – search raw headers
- `db.execute_sql_query(sql_query, limit)` – run custom SELECT queries (security-restricted)

## Complete Documentation

For detailed setup, troubleshooting, and advanced integration options, see:
- **Full Documentation**: [`docs/mcp_server.md`](../docs/mcp_server.md)
- **Tool Reference**: All 22 database tools with parameters and examples
- **Protocol Details**: Technical MCP implementation specifics
- **Troubleshooting**: Platform-specific common issues and solutions
