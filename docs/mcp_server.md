# NittyMail MCP Server - Complete Documentation

A standalone Model Context Protocol server exposing 22 NittyMail email database tools for Claude Desktop, Gemini, GPT, and other MCP clients.

## Overview

**Note:** The NittyMail MCP Server is packaged to run inside a Docker container, so you do not need a local Ruby development environment. The setup instructions below use `docker compose`.

Provides the same database tools as the `query` command via the standardized MCP protocol, enabling natural language interaction with your email database through various AI platforms.

**Quick Start**: See [`core/README_MCP.md`](../core/README_MCP.md) for setup summary.

## Configuration

Environment variables (from `core/config/.env`):
- **`DATABASE`** (required): SQLite database file path
- **`ADDRESS`** (optional): Gmail address context for filtering  
- **`OLLAMA_HOST`** (optional): Ollama endpoint for vector search
- **`LOG_LEVEL`** (optional): DEBUG, INFO, WARN, ERROR (default: INFO)

## Available Tools (22 Total)

### Core Email Operations
- **`db.list_earliest_emails`** - Fetch earliest emails by date
- **`db.get_email_full`** - Single email with full content/headers
- **`db.filter_emails`** - Search with filters (sender, subject, mailbox, dates)  
- **`db.search_emails`** - Semantic vector search (requires embeddings)
- **`db.count_emails`** - Count emails matching criteria

### Analytics & Statistics
- **`db.get_email_stats`** - Overview: totals, date range, top senders/domains
- **`db.get_top_senders`** - Most frequent senders ranked by count
- **`db.get_top_domains`** - Most frequent sender domains  
- **`db.get_largest_emails`** - Largest emails by stored size (attachments filter)
- **`db.get_mailbox_stats`** - Email distribution per mailbox/folder
- **`db.get_emails_by_date_range`** - Volume analytics (daily/monthly/yearly)
- **`db.get_emails_with_attachments`** - Filter emails with attachments
- **`db.get_email_thread`** - All emails in Gmail conversation thread

### Time-based Analytics
- **`db.get_email_activity_heatmap`** - Email volume by hour/day for heatmap visualization
- **`db.get_response_time_stats`** - Response times between consecutive emails in threads
- **`db.get_email_frequency_by_sender`** - Email frequency patterns per sender over time
- **`db.get_seasonal_trends`** - Email volume trends by month/season over multiple years

### Advanced Filtering & Search
- **`db.get_emails_by_size_range`** - Filter by size categories (small/medium/large/huge)
- **`db.get_duplicate_emails`** - Find duplicate emails by subject or message_id
- **`db.search_email_headers`** - Search email headers using pattern matching
- **`db.get_emails_by_keywords`** - Keyword search with frequency scoring
- **`db.execute_sql_query`** - Execute arbitrary read-only SQL SELECT queries (security-restricted)

## Tool Reference

Each tool is exposed via MCP with this call shape:
- Method: `tools/call`
- Params: `{ "name": "<tool_name>", "arguments": { ... } }`
- Result content: array with a single `{type: "text", text: <json>}` item

Fields use these conventions unless noted:
- `date`: ISO8601 string or null (parsed from headers)
- `internaldate`: IMAP INTERNALDATE captured during sync
- `from`: sender display string (may include name and email)
- `rfc822_size`: integer; bytesize of stored raw message (`encoded`)
- `size_bytes`: integer; SQLite `length(encoded)` of the stored RFC822 message (used in size-focused tools)

db.list_earliest_emails
- Params: `limit` (integer, default 100)
- Returns: list of `{id, address, mailbox, uid, uidvalidity, message_id, date, internaldate, from, subject, rfc822_size}` ordered by ascending `date`

db.get_email_full
- Params: any of `id` (string), `mailbox` (string), `uid` (integer), `uidvalidity` (integer), `message_id` (string), `from_contains` (string), `subject_contains` (string), `date` (YYYY or YYYY-MM-DD), `order` (date_asc|date_desc)
- Returns: single object including common fields plus:
  - `encoded` (raw RFC822)
  - `envelope_to, envelope_cc, envelope_bcc, envelope_reply_to` (JSON arrays)
  - `envelope_in_reply_to` (string or null)
  - `envelope_references` (JSON array)

db.filter_emails
- Params: `from_contains` (string), `from_domain` (string or `@domain`), `subject_contains` (string), `mailbox` (string), `date_from` (YYYY-MM-DD), `date_to` (YYYY-MM-DD), `order` (date_asc|date_desc), `limit` (integer, default 100)
- Returns: list of `{id, address, mailbox, uid, uidvalidity, message_id, date, internaldate, from, subject, rfc822_size}`

db.search_emails
- Params: `query` (string, required), `item_types` (array of subject|body), `limit` (integer, default 100)
- Requires: embeddings present and `OLLAMA_HOST` configured
- Returns: list of `{id, address, mailbox, uid, uidvalidity, message_id, date, from, subject, score}` ordered by ascending `score`

db.count_emails
- Params: same filters as `db.filter_emails`
- Returns: `{count}`

db.get_email_stats
- Params: `top_limit` (integer, default 10)
- Returns: `{ total_emails, date_range: {earliest, latest}, top_senders: [{from, count}], top_domains: [{domain, count}], mailbox_distribution: [{mailbox, count}] }`

db.get_top_senders
- Params: `limit` (integer, default 20), `mailbox` (string)
- Returns: `[{from, count}]`

db.get_top_domains
- Params: `limit` (integer, default 20)
- Returns: `[{domain, count}]`

db.get_largest_emails
- Params: `limit` (integer, default 5), `attachments` (any|with|without, default any), `mailbox` (string), `from_domain` (string)
- Returns: list of `{id, address, mailbox, uid, uidvalidity, message_id, date, internaldate, from, subject, rfc822_size, size_bytes}` ordered by descending `size_bytes`

db.get_mailbox_stats
- Params: none
- Returns: `[{mailbox, count}]`

db.get_emails_by_date_range
- Params: `period` (daily|monthly|yearly, default monthly), `date_from` (YYYY-MM-DD), `date_to` (YYYY-MM-DD), `limit` (integer, default 50)
- Returns: `[{period, count}]` where period is formatted per aggregation

db.get_emails_with_attachments
- Params: `mailbox` (string), `date_from` (YYYY-MM-DD), `date_to` (YYYY-MM-DD), `limit` (integer, default 100)
- Returns: list of `{id, address, mailbox, uid, uidvalidity, message_id, date, internaldate, from, subject, rfc822_size}` filtered to `has_attachments = true`

db.get_email_thread
- Params: `thread_id` (string, required), `order` (date_asc|date_desc, default date_asc)
- Returns: list of `{id, address, mailbox, uid, uidvalidity, message_id, date, internaldate, from, subject, rfc822_size}` within the given `x_gm_thrid`

**Time-based Analytics Tools:**

db.get_email_activity_heatmap
- Params: `date_from` (YYYY-MM-DD), `date_to` (YYYY-MM-DD)
- Returns: `[{hour, day_of_week, day_number, count}]` where hour is 0-23, day_of_week is Sunday-Saturday, day_number is 0-6

db.get_response_time_stats  
- Params: `limit` (integer, default 50)
- Returns: `[{thread_id, from_sender, to_sender, response_time_hours, prev_date, curr_date}]` ordered by response time

db.get_email_frequency_by_sender
- Params: `sender` (string, contains match), `period` (daily|monthly|yearly, default monthly), `limit` (integer, default 50)  
- Returns: `[{from, period, count}]` showing email frequency per sender over time

db.get_seasonal_trends
- Params: `years_back` (integer, default 3)
- Returns: `[{year, month, count, season, month_name}]` with seasonal classification

**Advanced Filtering Tools:**

db.get_emails_by_size_range
- Params: `size_category` (small|medium|large|huge, default large), `limit` (integer, default 100)
- Returns: list of `{id, address, mailbox, uid, uidvalidity, message_id, date, from, subject, size_bytes}` filtered by size ranges: small <10KB, medium 10KB-100KB, large >100KB, huge >1MB

db.get_duplicate_emails
- Params: `similarity_field` (subject|message_id, default subject), `limit` (integer, default 100)
- Returns: `[{similarity_field, duplicate_count, email_ids}]` where email_ids is array of duplicate record IDs

db.search_email_headers
- Params: `header_pattern` (string), `limit` (integer, default 100)
- Returns: list of `{id, address, mailbox, uid, uidvalidity, message_id, date, from, subject}` matching header pattern in raw RFC822 content

db.get_emails_by_keywords
- Params: `keywords` (array of strings, required), `match_mode` (any|all, default any), `limit` (integer, default 100)
- Returns: list of `{id, address, mailbox, uid, uidvalidity, message_id, date, from, subject, keyword_match_count, keyword_match_score}` ordered by match score

**SQL Query Tool:**

db.execute_sql_query
- Params: `sql_query` (string, required), `limit` (integer, default 1000)
- Returns: `{query, row_count, rows}` where rows is array of result objects
- Security: Only SELECT and WITH (CTE) statements allowed. Blocks INSERT, UPDATE, DELETE, DROP, CREATE, ALTER, TRUNCATE, PRAGMA, and transaction commands
- Auto-adds LIMIT clause if not specified to prevent runaway queries
- Example: `"SELECT mailbox, COUNT(*) as count FROM email GROUP BY mailbox ORDER BY count DESC LIMIT 5"`

## Client Integration

### Claude Desktop

Add to your Claude Desktop MCP configuration file:

**macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`
**Windows**: `%APPDATA%/Claude/claude_desktop_config.json`
**Linux**: `~/.config/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "nittymail": {
      "command": "docker",
      "args": [
        "compose", "-f", "/absolute/path/to/nittymail/core/docker-compose.yml",
        "run", "--rm", "ruby", "./mcp_server.rb"
      ],
      "cwd": "/absolute/path/to/nittymail/core",
      "env": {
        "DATABASE": "data/your-email.sqlite3",
        "ADDRESS": "your@gmail.com"
      }
    }
  }
}
```

After adding the configuration, restart Claude Desktop. You should see "NittyMail connected" in the status area.

### Google AI Studio / Gemini API

You can connect the Gemini CLI to the NittyMail MCP server, allowing you to use the database tools in your chat sessions.

**Recommended Method: Using `gemini mcp`**

The `gemini mcp` command allows you to add, list, and remove MCP server configurations, making it easier to manage them.

**1. Add the NittyMail MCP Server:**

Run the following command to add the NittyMail server to your Gemini CLI configuration. Replace `/path/to/your/nittymail/core` with the absolute path to the `core` directory.

```bash
gemini mcp add nittymail "docker compose run --rm ruby ./mcp_server.rb" --scope project --description "NittyMail Email Client"
```

**Explanation:**

*   `gemini mcp add nittymail ...`: This registers a new MCP server named `nittymail`.
*   `"docker compose run --rm ruby ./mcp_server.rb"`: This is the command that the Gemini CLI will execute to start the server.
*   `--scope project`: This saves the configuration in a `.gemini/settings.json` file in your project's root directory. This is the recommended scope for project-specific tools.
*   `--description "..."`: A helpful description for the server.

**2. Chat with the NittyMail Server:**

Once the server is added, you can start a chat session and the Gemini CLI will automatically connect to it.

```bash
gemini chat "show me my top 5 senders"
```

You can verify that the server is connected by running `gemini mcp list`.

**Alternative Method: Using Command-Line Flags**

You can also connect to the MCP server directly using command-line flags, without adding it to your configuration. This is useful for quick tests.

```bash
gemini chat \
  --mcp-server "stdio://docker compose run --rm ruby ./mcp_server.rb" \
  --mcp-server-cwd "/path/to/your/nittymail/core"
```


### OpenAI Codex / GPT with MCP

Currently, OpenAI's models don't natively support MCP. However, you can use MCP bridge tools:

#### Option 1: MCP-to-OpenAI Bridge

```bash
# Install mcp-client-openai bridge
npm install -g @modelcontextprotocol/client-openai

# Start your MCP server
docker compose run --rm ruby ./mcp_server.rb &
MCP_PID=$!

# Bridge to OpenAI API
mcp-openai-bridge \
  --mcp-command "docker compose run --rm ruby ./mcp_server.rb" \
  --mcp-cwd "/absolute/path/to/nittymail/core" \
  --openai-key "$OPENAI_API_KEY" \
  --port 3001

# Use with any OpenAI-compatible client
curl -X POST http://localhost:3001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "model": "gpt-4",
    "messages": [{"role": "user", "content": "Show me my email statistics"}]
  }'

kill $MCP_PID
```

#### Option 2: Direct Integration with OpenAI Python SDK

```python
#!/usr/bin/env python3
import subprocess
import json
import openai
from typing import List, Dict

class NittyMailMCPClient:
    def __init__(self, cwd: str):
        self.cwd = cwd
        self.process = None
    
    def start_server(self):
        cmd = ["docker", "compose", "run", "--rm", "ruby", "./mcp_server.rb"]
        self.process = subprocess.Popen(
            cmd, 
            cwd=self.cwd,
            stdin=subprocess.PIPE, 
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        # Initialize
        init_req = {
            "jsonrpc": "2.0", "id": 1, "method": "initialize", 
            "params": {"protocolVersion": "2024-11-05", "capabilities": {}}
        }
        self.process.stdin.write(json.dumps(init_req) + "\n")
        self.process.stdin.flush()
        self.process.stdout.readline()  # consume response
    
    def call_tool(self, name: str, arguments: Dict) -> Dict:
        request = {
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": name, "arguments": arguments}
        }
        self.process.stdin.write(json.dumps(request) + "\n") 
        self.process.stdin.flush()
        
        response = json.loads(self.process.stdout.readline())
        if "result" in response:
            return json.loads(response["result"]["content"][0]["text"])
        else:
            raise Exception(f"Tool call failed: {response.get('error')}")

# Usage
client = NittyMailMCPClient("/absolute/path/to/nittymail/core")
client.start_server()

# Get email stats
stats = client.call_tool("db.get_email_stats", {"top_limit": 5})
print(f"Total emails: {stats['total_emails']}")

# Use with OpenAI
openai_client = openai.OpenAI()
response = openai_client.chat.completions.create(
    model="gpt-4",
    messages=[
        {"role": "system", "content": f"Email statistics: {json.dumps(stats)}"},
        {"role": "user", "content": "Analyze my email patterns"}
    ]
)
print(response.choices[0].message.content)
```

### Generic MCP Client

For other tools that support MCP:

```bash
# Install the reference MCP client
npm install -g @modelcontextprotocol/client

# Connect to your server
mcp-client connect \
  --command "docker compose run --rm ruby ./mcp_server.rb" \
  --cwd "/absolute/path/to/nittymail/core" \
  --env DATABASE=data/your-email.sqlite3 \
  --env ADDRESS=your@gmail.com
```

### Custom Integration

You can integrate with any system by speaking the MCP protocol directly:

```bash
# Manual JSON-RPC over stdio
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | \
  docker compose run --rm ruby ./mcp_server.rb

# Get available tools and their schemas
printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"db.get_email_stats","arguments":{"top_limit":3}}}\n' | \
  docker compose run --rm ruby ./mcp_server.rb
```

## Testing & Verification

**Note:** The NittyMail MCP Server is packaged to run inside a Docker container, so you do not need a local Ruby development environment. The setup instructions below use `docker compose`.

```bash
# Automated tests
docker compose run --rm ruby bundle exec rspec spec/mcp_server_spec.rb

# Manual verification (see core/README_MCP.md for quick tests)
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | docker compose run --rm ruby ./mcp_server.rb 2>/dev/null | jq '.result.tools | length'
```


## Protocol Details

The server implements MCP protocol version `2024-11-05` with these capabilities:

- **Initialize**: Handshake and capability negotiation
- **Tools List**: Enumerate available database tools
- **Tools Call**: Execute database operations 
- **Ping**: Health check endpoint

### Request/Response Format

All communication uses JSON-RPC 2.0 over STDIN/STDOUT:

```json
// Tool call request
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "db.get_email_stats", 
    "arguments": {"top_limit": 10}
  }
}

// Response
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"total_emails\": 1000, ...}"
      }
    ]
  }
}
```

## Error Handling

The server provides detailed error responses:
- **Parse errors**: JSON syntax issues
- **Method not found**: Unknown MCP methods  
- **Tool execution errors**: Database or tool failures
- **Configuration errors**: Missing environment variables

## Logging

Server logs to STDERR with configurable levels:
- `DEBUG`: Request/response details and SQL queries
- `INFO`: Tool calls and connection events (default)
- `WARN`: Recoverable issues
- `ERROR`: Critical failures

## Security Notes

- The MCP server has full access to your email database
- No authentication is built into the MCP protocol - secure at the process level
- Consider network isolation if exposing beyond localhost
- Database is opened in WAL mode for concurrent access safety

## Troubleshooting

**Server won't start:**
- Check `DATABASE` environment variable points to existing file
- Ensure Docker dependencies are installed by running `docker compose run --rm ruby bundle install`

**Tool calls fail:**
- Check database schema is up to date
- For vector search, ensure embeddings are populated (`./cli.rb embed`)
- Verify `OLLAMA_HOST` is accessible for semantic search

**Performance issues:**
- Database connections are per-request - consider connection pooling for high volume
- Vector search requires `OLLAMA_HOST` access - network latency affects performance

## Client-Specific Setup Issues

### Claude Desktop

**"Server not connecting":**
- Ensure all paths in the configuration are absolute paths, not relative
- Verify Docker is running and accessible from Claude Desktop's process
- Check that the `cwd` directory exists and contains `docker-compose.yml`
- Restart Claude Desktop after configuration changes

**"Permission denied":**
- Ensure Docker doesn't require sudo for the user running Claude Desktop
- On macOS, grant Full Disk Access to Claude in System Preferences > Security & Privacy

### Gemini CLI

**"Command not found":**
```bash
# Install with pip user flag if system install fails
pip install --user google-generativeai-cli
export PATH="$PATH:$HOME/.local/bin"
```

**"MCP server connection failed":**
- Verify the Docker compose command works manually first
- Check that the `--mcp-server-cwd` path is absolute and correct
- Ensure your `.env` file has proper database path

### OpenAI Bridge

**"Bridge installation fails":**
```bash
# Try with different Node.js versions
nvm install 18
nvm use 18
npm install -g @modelcontextprotocol/client-openai
```

**"Bridge server won't start":**
- Verify `OPENAI_API_KEY` environment variable is set
- Check that the specified port (3001) is available
- Test the MCP server works standalone first

### Generic Issues

**"Database locked" errors:**
- Only one process can write to SQLite at a time
- Stop other NittyMail processes (sync, embed, query) before starting MCP server
- Check for stale lock files in the database directory

**"Docker command fails":**
```bash
# Test Docker access manually
docker compose -f /absolute/path/to/docker-compose.yml run --rm ruby ruby --version

# If fails, check Docker daemon and file permissions
sudo systemctl status docker  # Linux
brew services list | grep docker  # macOS
```

**"Environment variables not loaded":**
- Ensure `.env` file is in the correct directory (same as `mcp_server.rb`)
- Check file permissions are readable by the Docker process
- Use absolute paths in environment variables, not relative paths
### db.get_largest_emails

Returns the largest emails ranked by stored message size (`length(encoded)`), optionally filtered by attachments.

- Parameters:
  - `limit`: integer, default 5
  - `attachments`: string enum: `any`, `with`, `without` (default `any`)
  - `mailbox`: optional mailbox filter (e.g., INBOX, [Gmail]/All Mail)
  - `from_domain`: optional sender domain filter (e.g., example.com)
- Returns fields: `id, address, mailbox, uid, uidvalidity, message_id, date, from, subject, size_bytes`

Example request:
```json
{ "jsonrpc":"2.0", "id": 1, "method": "tools/call", "params": { "name": "db.get_largest_emails", "arguments": { "limit": 5, "attachments": "any", "mailbox": "INBOX", "from_domain": "example.com" } } }
```
