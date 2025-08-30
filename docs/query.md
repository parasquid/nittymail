# Query: LLM + Tools over Your Mail

The `query` subcommand lets you ask natural‑language questions against your SQLite mailbox using an Ollama chat model. When the model supports tools, it calls database functions to fetch facts; otherwise, NittyMail falls back to a robust heuristic that directly queries the DB.

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
  - “about/ regarding/ on <topic>” → vector search (requires embeddings) with a subject‑contains fallback when embeddings aren’t available

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

- `db.get_email_stats(top_limit)` – overview: totals, date range, top senders/domains
- `db.get_top_senders(limit, mailbox)` – most frequent senders
- `db.get_top_domains(limit)` – most frequent sender domains
- `db.get_largest_emails(limit, attachments, mailbox, from_domain)` – largest messages by stored size; `attachments` is one of `any|with|without`
- `db.filter_emails(...)` – filter by sender/subject contains, mailbox, dates
- `db.search_emails(query, item_types, limit)` – semantic search (needs embeddings)

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
