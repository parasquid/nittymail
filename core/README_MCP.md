# NittyMail MCP Server - Quick Start

**Note:** This server is designed to be run via Docker. A local Ruby installation is not required.

A standalone Model Context Protocol server that exposes all 12 NittyMail email database tools for use with Claude Desktop and other MCP clients.

## Quick Test

```bash
# Test server startup
docker compose run --rm ruby ./mcp_server.rb

# Test with a simple request  
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  docker compose run --rm ruby ./mcp_server.rb 2>/dev/null | jq '.result.tools | length'
# Should output: 12
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
    gemini mcp add nittymail "docker compose run --rm ruby ./mcp_server.rb" --scope project
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

## Complete Documentation

For detailed setup, troubleshooting, and advanced integration options, see:
- **Full Documentation**: [`docs/mcp_server.md`](../docs/mcp_server.md)
- **Tool Reference**: All 12 database tools with parameters and examples
- **Protocol Details**: Technical MCP implementation specifics
- **Troubleshooting**: Platform-specific common issues and solutions