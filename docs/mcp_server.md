# NittyMail MCP Server - Complete Documentation

A standalone Model Context Protocol server exposing 12 NittyMail email database tools for Claude Desktop, Gemini, GPT, and other MCP clients.

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

## Available Tools (13 Total)

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
- Returns fields: `id, address, mailbox, uid, uidvalidity, message_id, date, from, subject, size_bytes`

Example request:
```json
{ "jsonrpc":"2.0", "id": 1, "method": "tools/call", "params": { "name": "db.get_largest_emails", "arguments": { "limit": 5, "attachments": "any" } } }
```
