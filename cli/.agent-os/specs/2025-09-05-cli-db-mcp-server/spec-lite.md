# Spec Summary (Lite)

Add `cli db mcp`, a local stdio MCP server exposing read-only email database tools to MCP-compatible agents. It provides filtered retrieval, analytics, and a secure read-only SQL interface with enforced limits and validation; semantic vector search is stubbed for now and will be implemented later using embeddings. This server uses the local database only and opens no IMAP connections.
