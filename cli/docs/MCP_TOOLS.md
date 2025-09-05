# MCP Tools Reference

This document describes all 23 MCP tools available in the NittyMail CLI DB MCP server, including their parameters, return shapes, and usage examples.

## Overview

The MCP server provides read-only access to your local email database through a comprehensive set of tools. All tools enforce security measures including:
- Parameter validation and sanitization
- Configurable result limits (max 1000 rows by default)
- SQL injection prevention
- Read-only database access

**Note**: `db.search_emails` is currently stubbed and returns an empty list. Vector search functionality will be implemented in a future release.

## Email Retrieval Tools

### `db.list_earliest_emails`
Lists the earliest emails in the database by date.

**Parameters:**
- `limit` (optional, integer): Maximum number of results (default: 100)

**Returns:** Array of email objects with base projection fields

**Example:**
```json
{
  "name": "db.list_earliest_emails",
  "arguments": {"limit": 10}
}
```

### `db.get_email_full`
Retrieves the complete email record by ID, including raw content.

**Parameters:**
- `id` (required, integer): Email database ID

**Returns:** Complete email object with all database fields

**Example:**
```json
{
  "name": "db.get_email_full",  
  "arguments": {"id": 12345}
}
```

### `db.filter_emails`
Filters emails by mailbox and sender criteria.

**Parameters:**
- `mailbox` (optional, string): Mailbox name to filter by
- `from_contains` (optional, string): Text to search in from field
- `from_domain` (optional, string): Domain to filter sender by (e.g., "example.com" or "@example.com")
- `limit` (optional, integer): Maximum number of results (default: 100)

**Returns:** Array of email objects with base projection fields

**Example:**
```json
{
  "name": "db.filter_emails",
  "arguments": {"mailbox": "INBOX", "from_domain": "github.com", "limit": 50}
}
```

## Analytics Tools

### `db.get_email_stats`
Provides comprehensive database statistics.

**Parameters:** None

**Returns:** Object with database statistics
```json
{
  "total_emails": 15420,
  "unique_senders": 1205,
  "total_size_bytes": 2147483648,
  "average_size_bytes": 139284,
  "mailbox_count": 8,
  "date_range": {
    "earliest": "2020-01-01T00:00:00Z",
    "latest": "2025-09-05T16:30:00Z"
  }
}
```

### `db.count_emails`
Simple count of emails, optionally filtered by mailbox.

**Parameters:**
- `mailbox` (optional, string): Mailbox to count emails in

**Returns:** Object with count
```json
{"count": 1542}
```

### `db.get_top_senders`
Lists top email senders by message count.

**Parameters:**
- `limit` (optional, integer): Maximum number of results (default: 20)

**Returns:** Array of sender objects
```json
[
  {"from": "notifications@github.com", "count": 342},
  {"from": "team@company.com", "count": 156}
]
```

### `db.get_top_domains`
Lists top sender domains by message count.

**Parameters:**
- `limit` (optional, integer): Maximum number of results (default: 10)

**Returns:** Array of domain objects
```json
[
  {"domain": "github.com", "count": 450},
  {"domain": "company.com", "count": 234}
]
```

### `db.get_largest_emails`
Lists emails by size (largest first).

**Parameters:**
- `from_domain` (optional, string): Filter by sender domain
- `limit` (optional, integer): Maximum number of results (default: 5)

**Returns:** Array of email objects with base projection fields plus size information

### `db.get_mailbox_stats`
Shows email count by mailbox.

**Parameters:** None

**Returns:** Array of mailbox statistics
```json
[
  {"mailbox": "INBOX", "count": 8420},
  {"mailbox": "Sent", "count": 1205}
]
```

## Date/Time Analysis Tools

### `db.get_emails_by_date_range`
Retrieves emails within a specific date range.

**Parameters:**
- `start_date` (required, string): Start date in ISO format or parseable format
- `end_date` (required, string): End date in ISO format or parseable format  
- `limit` (optional, integer): Maximum number of results (default: 100)

**Returns:** Array of email objects with base projection fields

**Example:**
```json
{
  "name": "db.get_emails_by_date_range",
  "arguments": {
    "start_date": "2025-01-01",
    "end_date": "2025-01-31",
    "limit": 200
  }
}
```

### `db.get_email_activity_heatmap`
Shows email activity patterns by hour of day and day of week.

**Parameters:**
- `limit` (optional, integer): Maximum number of data points (default: 168 for full week)

**Returns:** Array of activity data points
```json
[
  {"hour_of_day": 9, "day_of_week": 1, "count": 45},
  {"hour_of_day": 14, "day_of_week": 3, "count": 32}
]
```
*Note: day_of_week: 0=Sunday, 1=Monday, etc.*

### `db.get_seasonal_trends`
Shows email volume trends by month and year.

**Parameters:**
- `limit` (optional, integer): Maximum number of data points (default: 24)

**Returns:** Array of trend data
```json
[
  {"year": 2024, "month": 12, "month_name": "December", "count": 856},
  {"year": 2025, "month": 1, "month_name": "January", "count": 492}
]
```

## Thread Analysis Tools

### `db.get_email_thread`
Retrieves all emails in a Gmail thread.

**Parameters:**
- `x_gm_thrid` (required, integer): Gmail thread ID
- `limit` (optional, integer): Maximum number of results (default: 50)

**Returns:** Array of email objects with base projection fields, ordered by date

**Example:**
```json
{
  "name": "db.get_email_thread",
  "arguments": {"x_gm_thrid": 1719234567890}
}
```

### `db.get_response_time_stats`
Analyzes response times in email conversations.

**Parameters:**
- `limit` (optional, integer): Maximum number of threads to analyze (default: 50)

**Returns:** Array of thread analysis objects
```json
[
  {
    "x_gm_thrid": 1719234567890,
    "message_count": 4,
    "first_message": "2025-01-15T09:00:00Z",
    "last_message": "2025-01-15T16:30:00Z", 
    "duration_seconds": 27000,
    "duration_hours": 7.5
  }
]
```

### `db.get_email_frequency_by_sender`
Shows email frequency over time for a specific sender.

**Parameters:**
- `sender_email` (required, string): Email address to analyze
- `limit` (optional, integer): Maximum number of date points (default: 365)

**Returns:** Array of frequency data
```json
[
  {"date": "2025-01-01", "count": 3},
  {"date": "2025-01-02", "count": 0},
  {"date": "2025-01-03", "count": 5}
]
```

## Content Search Tools

### `db.get_emails_with_attachments`
Lists emails that have attachments.

**Parameters:**
- `limit` (optional, integer): Maximum number of results (default: 50)

**Returns:** Array of email objects with base projection fields

### `db.search_email_headers`
Searches within email header fields.

**Parameters:**
- `query` (required, string): Search query
- `header_field` (optional, string): Field to search in (default: "subject")
  - Valid values: "subject", "from", "to_emails", "cc_emails", "bcc_emails", "message_id"
- `limit` (optional, integer): Maximum number of results (default: 50)

**Returns:** Array of email objects with base projection fields

**Example:**
```json
{
  "name": "db.search_email_headers",
  "arguments": {
    "query": "meeting",
    "header_field": "subject",
    "limit": 25
  }
}
```

### `db.get_emails_by_keywords`
Searches email content by keywords with AND/OR logic.

**Parameters:**
- `keywords` (required, string or array): Keywords to search for
- `search_field` (optional, string): Field to search in (default: "plain_text")
  - Valid values: "plain_text", "markdown", "subject", "raw"  
- `match_all` (optional, boolean): If true, all keywords must match (AND logic). If false, any keyword can match (OR logic). Default: false
- `limit` (optional, integer): Maximum number of results (default: 50)

**Returns:** Array of email objects with base projection fields

**Example:**
```json
{
  "name": "db.get_emails_by_keywords",
  "arguments": {
    "keywords": "project,deadline,urgent",
    "search_field": "plain_text", 
    "match_all": false,
    "limit": 100
  }
}
```

## Advanced Tools

### `db.get_emails_by_size_range`
Finds emails within a specific size range.

**Parameters:**
- `min_size` (required, integer): Minimum size in bytes (must be >= 0)
- `max_size` (required, integer): Maximum size in bytes (must be > min_size)
- `limit` (optional, integer): Maximum number of results (default: 50)

**Returns:** Array of email objects with base projection fields plus `size_bytes`

**Example:**
```json
{
  "name": "db.get_emails_by_size_range",
  "arguments": {
    "min_size": 1000000,
    "max_size": 10000000,
    "limit": 20
  }
}
```

### `db.get_duplicate_emails`
Finds emails with duplicate message IDs or Gmail message IDs.

**Parameters:**
- `field` (optional, string): Field to check for duplicates (default: "message_id")
  - Valid values: "message_id", "x_gm_msgid"
- `limit` (optional, integer): Maximum number of results (default: 50)

**Returns:** Array of email objects with base projection fields

**Example:**
```json
{
  "name": "db.get_duplicate_emails", 
  "arguments": {"field": "message_id", "limit": 100}
}
```

### `db.execute_sql_query`
Executes a read-only SQL query with safety validation.

**Parameters:**
- `sql_query` (required, string): SQL query to execute (SELECT or WITH only)

**Returns:** Object with query results
```json
{
  "query": "SELECT COUNT(*) as total FROM emails WHERE mailbox = 'INBOX'",
  "row_count": 1,
  "rows": [{"total": 8420}]
}
```

**Security Features:**
- Only SELECT and WITH statements allowed
- Forbidden keywords blocked (INSERT, UPDATE, DELETE, DROP, etc.)
- Automatic LIMIT enforcement if not specified
- Multi-statement queries rejected

**Example:**
```json
{
  "name": "db.execute_sql_query",
  "arguments": {
    "sql_query": "SELECT mailbox, COUNT(*) as count FROM emails GROUP BY mailbox ORDER BY count DESC"
  }
}
```

### `db.search_emails` (Stubbed)
**Note**: This tool is currently stubbed and returns an empty array. Vector search functionality will be implemented in a future release.

**Parameters:**
- `query` (required, string): Search query
- `limit` (optional, integer): Maximum number of results

**Returns:** Empty array `[]`

## Common Return Fields (Base Projection)

Most list-returning tools include these standard fields:
```json
{
  "id": 12345,
  "address": "user@example.com",
  "mailbox": "INBOX", 
  "uid": 98765,
  "uidvalidity": 42,
  "message_id": "<abc123@example.com>",
  "x_gm_msgid": 1719234567890,
  "date": "2025-01-15T14:30:00Z",
  "internaldate": "2025-01-15T14:30:00Z",
  "internaldate_epoch": 1736949000,
  "from": "sender@example.com", 
  "subject": "Email Subject",
  "rfc822_size": 2048
}
```

## Error Handling

All tools return structured error responses for invalid parameters:
```json
{
  "error": "start_date is required"
}
```

Common error conditions:
- Missing required parameters
- Invalid parameter types or values  
- Database connection issues
- SQL syntax errors (for `db.execute_sql_query`)

## Usage Notes

- All date fields support both epoch timestamps and ISO 8601 strings
- LIKE pattern searches automatically escape wildcards to prevent abuse
- Result limits are enforced at the database level for performance
- The server maintains read-only access - no data modification is possible
- Environment variables can configure default limits and database paths