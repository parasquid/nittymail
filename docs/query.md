# Query: LLM + Tools over Your Mail

The `query` subcommand lets you ask natural‑language questions against your SQLite mailbox using an Ollama chat model with tool calling. A tool‑capable model and a running Ollama instance are required; there is no heuristic fallback.

## Quickstart

```bash
# 1) Pull the recommended model for excellent tool calling
ollama pull qwen2.5:7b-instruct

# Optional alternatives:
# ollama pull llama3.1:8b-instruct  # More capable but slower
# ollama pull llama3.2:3b           # Faster but limited tool support

# 2) Configure env
cp core/config/.env.sample core/config/.env
# Edit core/config/.env and set ADDRESS, PASSWORD, DATABASE
export OLLAMA_HOST=http://localhost:11434

# 3) Install gems (Docker)
docker compose run --rm ruby bundle

# 4) Sync mail into SQLite
docker compose run --rm ruby ./cli.rb sync

# 5) (Optional) Backfill embeddings for semantic topic search
docker compose run --rm ruby ./cli.rb embed

# 6) Query your mail
docker compose run --rm ruby ./cli.rb query 'give me the 5 earliest emails I have'
# Or specify a different model explicitly
docker compose run --rm ruby ./cli.rb query --model llama3.1:8b-instruct 'show me 20 emails that talk about dancing'
```

## Prerequisites

- Sync some mail into a SQLite DB (see [`core/README.md`](../core/README.md)).
- Ollama running and reachable via `OLLAMA_HOST` (e.g., `http://localhost:11434`).
- For semantic topic search, populate embeddings first with `./cli.rb embed`.

## Models

- Default: `qwen2.5:7b-instruct` (excellent tool calling support and good performance)
- Alternative models:
  - `llama3.1:8b-instruct` (more capable but slower)
  - `llama3.2:3b` (fastest but limited tool support)

Pull examples:

```bash
# Recommended default (best balance of capability and speed)
ollama pull qwen2.5:7b-instruct

# Alternative options
ollama pull llama3.1:8b-instruct  # More capable, slower
ollama pull llama3.2:3b           # Faster, limited tool support
```

## Usage

```bash
docker compose run --rm ruby ./cli.rb query 'give me the 5 earliest emails I have'

docker compose run --rm ruby ./cli.rb query \
  --database core/data/your-email.sqlite3 \
  --ollama-host http://localhost:11434 \
  --model qwen2.5:7b-instruct \
  --limit 50 'show me emails about dancing'
```

Environment defaults:
- `DATABASE`: path to your SQLite file (required unless `--database` is provided)
- `ADDRESS`: optional Gmail address; used as a default filter/context
- `OLLAMA_HOST`: Ollama endpoint for chat and embeddings
- `QUERY_MODEL`: default chat model (defaults to `qwen2.5:7b-instruct`)

## Capabilities

- Default limit: If no limit is specified in the prompt, `100` results are returned at most.
- Earliest/Latest:
  - “earliest”, “oldest” → date ascending
  - “latest”, “newest” → date descending
- Date ranges:
  - “between 2015 and 2016”
  - “from 2020-01-01 to 2020-12-31”
  - “since 2019”, “after 2018”
  - “before 2021-02-01”, “until 2021-02-01”
- Mailbox filters:
  - “in inbox”, “in sent”, “in [Gmail]/All Mail”, “label Work”
- Sender filters:
  - By domain: “from @example.com” / “from example.com”
  - By name/email substring: “from ayaka” (case‑insensitive)
- Size-based:
  - "largest emails" via MCP tool `db.get_largest_emails(limit, attachments, mailbox, from_domain)`; `attachments` is one of `any|with|without`.
- Topic search:
  - “about/ regarding/ on <topic>” → vector search (requires embeddings). If embeddings or the vec extension are unavailable, this tool returns no results.

### Full Email Retrieval

- Return the full raw email contents (RFC822) when you uniquely identify an email:
  - By database id: “show email id 12345”, “open #12345”
  - By Gmail uid + mailbox (and optional UIDVALIDITY): “show email uid 4242 in INBOX”, “open uid 999 in [Gmail]/All Mail uidvalidity 12”
  - By Message-ID: “show message-id <abcdef@mail.example.com>”
  - By sender + date: “show the email from Ayaka on 2008-01-06”

Examples:

```bash
# By db id
docker compose run --rm ruby ./cli.rb query 'show email id 12345'

# By uid + mailbox
docker compose run --rm ruby ./cli.rb query 'open uid 4242 in INBOX'

# By Message-ID
docker compose run --rm ruby ./cli.rb query 'show message-id <abcdef@mail.example.com>'

# By sender + date
docker compose run --rm ruby ./cli.rb query 'show the email from ayaka on 2008-01-06'
```

## Examples

```bash
# Earliest 5
docker compose run --rm ruby ./cli.rb query 'give me the 5 earliest emails I have'

# Latest in Sent
docker compose run --rm ruby ./cli.rb query 'show me 20 latest emails in sent'

# Date range + mailbox
docker compose run --rm ruby ./cli.rb query 'show 10 emails in [Gmail]/All Mail between 2021 and 2022'

# Sender domain
docker compose run --rm ruby ./cli.rb query 'all mail from @example.com'

# Topic (semantic)
docker compose run --rm ruby ./cli.rb query 'show me 20 emails that talk about dancing'
```

## MCP Tools Cheat Sheet (Quick)

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

## How It Works

The query system works exclusively through LLM-powered tool calling:

- **LLM with Tools**: The agent exposes database functions as tools:
  - `db.list_earliest_emails(limit)` - for earliest/oldest queries
  - `db.filter_emails(from_contains, from_domain, subject_contains, mailbox, date_from, date_to, order, limit)` - for filtered searches
  - `db.search_emails(query, item_types, limit)` - for semantic/vector similarity search
  - `db.get_email_full(...)` - for retrieving complete email content by ID, UID, or other identifiers
  - `db.count_emails(...)` - for counting queries
- **Error Handling**: If Ollama is unavailable or the model doesn't support tools, the CLI returns a clear error message directing you to ensure Ollama is running with a tool-capable model.

## Notes

- Semantic search requires embeddings populated via `./cli.rb embed` and a working `OLLAMA_HOST`.
- The `ADDRESS` environment variable is used as a default filter when present.
- Heuristics apply a hard cap at formatting time, so you won’t see more than the requested limit even if an internal query over‑returns.

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