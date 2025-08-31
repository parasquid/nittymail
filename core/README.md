# NittyMail Core

This folder contains some common functionality, among which is a simple syncing script that will download all messages in a Gmail account to an sqlite3 database.

## Usage

**Note:** NittyMail is designed to be run via Docker, and a local Ruby installation is not required. All commands in this guide assume you have Docker and Docker Compose installed.

### Prerequisites

Before running NittyMail, you need to prepare your Gmail account:

#### 1. Enable IMAP Access
1. Open Gmail in your web browser
2. Click the gear icon (⚙️) in the top right corner
3. Select **"See all settings"**
4. Go to the **"Forwarding and POP/IMAP"** tab
5. In the **"IMAP access"** section, select **"Enable IMAP"**
6. Click **"Save Changes"** at the bottom

*Reference: [Gmail IMAP documentation](https://support.google.com/mail/answer/7126229)*

#### 2. Set Up App Password (Required for 2FA accounts)
If your Gmail account has 2-Factor Authentication enabled, you'll need an App Password:

1. Go to your [Google Account settings](https://myaccount.google.com/)
2. Select **"Security"** from the left sidebar
3. Under **"How you sign in to Google"**, click **"2-Step Verification"**
4. Scroll down and click **"App passwords"**
5. Select **"Mail"** from the dropdown
6. Choose **"Other (Custom name)"** and enter "NittyMail"
7. Click **"Generate"**
8. **Copy the 16-character password** - you'll use this instead of your regular Gmail password

*Reference: [Google App Passwords documentation](https://support.google.com/accounts/answer/185833)*

#### 3. Configure NittyMail
1. Copy the sample configuration file:
   ```bash
   cp core/config/.env.sample core/config/.env
   ```

2. Edit `core/config/.env` with your details:
   ```bash
   ADDRESS="your-email@gmail.com"
   PASSWORD="your-app-password-or-regular-password"
   DATABASE="data/your-email.sqlite3"
   ```

### Running NittyMail

With Docker and Docker Compose installed:

``` bash
# Install dependencies
docker compose run --rm ruby bundle

# Run the sync using .env file (you'll be prompted to confirm)
docker compose run --rm ruby ./cli.rb sync

# Or use CLI arguments (overrides .env values)
docker compose run --rm ruby ./cli.rb sync \
  --address user@gmail.com \
  --password your-app-password \
  --database data/user.sqlite3

# Optional: Add this alias to your terminal configuration for convenience
alias dcr='docker compose run --rm'
dcr ruby ./cli.rb sync
```

### Query (LLM + Tools)

Ask natural-language questions against your mail using an Ollama chat model with database tools. See a full guide in [docs/query.md](../docs/query.md).

```bash
# Basic: uses DATABASE and ADDRESS from .env
docker compose run --rm ruby ./cli.rb query 'give me the 5 earliest emails I have'

# Semantic: vector search (requires embeddings populated via `embed`)
docker compose run --rm ruby ./cli.rb query 'show me 20 emails that talk about dancing'

# Override defaults
docker compose run --rm ruby ./cli.rb query \
  --database core/data/your-email.sqlite3 \
  --ollama-host http://localhost:11434 \
  --model qwen2.5:7b-instruct \
  --limit 100 'show me all mail from ayaka'
```

Capabilities:
- Default limit 100 when not specified.
- “earliest/oldest” and “latest/newest” sort by date.
- Date ranges: “between 2015 and 2016”, “since 2019”, “before 2021-02-01”.
- Mailbox filters: “in inbox/sent/[Gmail]/All Mail”, “label Work”.
- Sender filters: “from @example.com”, “from ayaka”.
- Topic search: “about/regarding/on <topic>” uses vector search (requires embeddings); no subject fallback.

Notes:
- Uses the same env vars as sync: `DATABASE` (required) and `ADDRESS` (optional, used as context filter when present).
- Ollama must be reachable via `OLLAMA_HOST` or `--ollama-host`. Default chat model: `qwen2.5:7b-instruct` (excellent tool calling support). Override with `QUERY_MODEL` env var or `--model` flag. Alternative models: `llama3.1:8b-instruct` for more capability or `llama3.2:3b` for speed (limited tool support).
- Populate embeddings first with `./cli.rb embed` for semantic queries.

#### MCP Tools Cheat Sheet (Quick)

- `db.get_email_stats(top_limit)` – overview: totals, date range, top senders/domains
- `db.get_top_senders(limit, mailbox)` – most frequent senders
- `db.get_top_domains(limit)` – most frequent sender domains
- `db.get_largest_emails(limit, attachments, mailbox, from_domain)` – largest messages by stored size; `attachments` is one of `any|with|without`
- `db.filter_emails(...)` – filter by sender/subject contains, mailbox, dates
- `db.search_emails(query, item_types, limit)` – semantic search (needs embeddings)

### Advanced Options

**Automated/Non-interactive runs:**
```bash
# Using environment variable
SYNC_AUTO_CONFIRM=yes docker compose run --rm ruby ./cli.rb sync

# Using CLI flag
docker compose run --rm ruby ./cli.rb sync --auto-confirm
```

**Multi-threaded sync for large mailboxes:**
```bash
# Using environment variable
THREADS=4 docker compose run --rm ruby ./cli.rb sync

# Using CLI flag
docker compose run --rm ruby ./cli.rb sync --threads 4
```

**Mailbox preflight concurrency (discover UIDs per mailbox in parallel):**
```bash
# Using environment variable
MAILBOX_THREADS=4 docker compose run --rm ruby ./cli.rb sync

# Using CLI flag (overrides env var if provided)
docker compose run --rm ruby ./cli.rb sync --mailbox-threads 4
```

**Configure UID fetch batch size:**
```bash
# Using environment variable (default: 100)
FETCH_BATCH_SIZE=200 docker compose run --rm ruby ./cli.rb sync

# Using CLI flag (overrides env var if provided)
docker compose run --rm ruby ./cli.rb sync --fetch-batch-size 200
```

**Control IMAP retry attempts (for transient SSL/IO errors):**
```bash
# Using environment variable (default: 3; -1 retries indefinitely; 0 disables retries)
RETRY_ATTEMPTS=5 docker compose run --rm ruby ./cli.rb sync

# Using CLI flag (overrides env var if provided)
docker compose run --rm ruby ./cli.rb sync --retry-attempts 5
```
Behavior:
- On transient errors like `SSL_read: unexpected eof while reading`, NittyMail reconnects and retries the batch.
- `RETRY_ATTEMPTS = -1` (or `--retry-attempts -1`) retries indefinitely with backoff.
- `RETRY_ATTEMPTS = 0` (or `--retry-attempts 0`) disables retries (a failing batch is skipped for this run).

**Ignore specific mailboxes (skip syncing them):**
```bash
# Using environment variable (comma-separated; supports * and ? wildcards)
MAILBOX_IGNORE="[Gmail]/*,Spam,Trash" docker compose run --rm ruby ./cli.rb sync

# Using CLI flag (overrides env var if provided)
docker compose run --rm ruby ./cli.rb sync --ignore-mailboxes "[Gmail]/*,Spam,Trash"
```
Notes:
- Patterns are matched case-insensitively against full mailbox names.
- `*` matches any sequence; `?` matches a single character. Brackets in names (e.g., `[Gmail]`) are handled literally.
- Default recommendation: ignore Spam and Trash to reduce unnecessary data and speed up syncs. Example:
  - `MAILBOX_IGNORE="Spam,Trash"`

**Include only specific mailboxes (skip all others):**
```bash
# Using environment variable (comma-separated; supports * and ? wildcards)
ONLY_MAILBOXES="[Gmail]/All Mail,INBOX" docker compose run --rm ruby ./cli.rb sync

# Using CLI flag (overrides env var if provided)
docker compose run --rm ruby ./cli.rb sync --only "[Gmail]/All Mail" INBOX
# or comma-separated in a single arg
docker compose run --rm ruby ./cli.rb sync --only "[Gmail]/All Mail,INBOX"

# Combine with other options (threads, auto-confirm)
docker compose run --rm ruby ./cli.rb sync -t8 -m8 -y --only "[Gmail]/All Mail" INBOX
```
Notes:
- The include filter (`--only` / `ONLY_MAILBOXES`) is applied first; the ignore filter (`--ignore-mailboxes` / `MAILBOX_IGNORE`) is applied afterwards to the included set.
- Patterns are matched case-insensitively; `*` and `?` wildcards are supported.
- If `--only` matches zero mailboxes, the run logs that nothing will be processed.

**Strict error handling (debugging):**
```bash
# Using environment variable
STRICT_ERRORS=yes docker compose run --rm ruby ./cli.rb sync

# Using CLI flag (overrides env var if provided)
docker compose run --rm ruby ./cli.rb sync --strict-errors
```
Behavior:
- When enabled, NittyMail raises exceptions for cases that are otherwise logged and skipped, such as:
  - Duplicate row inserts (unique constraint violations)
  - Encoding/JSON errors when logging or building records (e.g., malformed headers)
  - Invalid or missing `Date:` headers that normally result in `date = NULL`
- Intended for diagnosing problematic messages; expect the sync to abort on the first such case.

**Quiet mode (reduced output):**
```bash
# Only show progress bars and high-level operations
docker compose run --rm ruby ./cli.rb sync --quiet

# Or via env var
QUIET=yes docker compose run --rm ruby ./cli.rb sync
```
Notes:
- Quiet mode suppresses per-message logs (from, subject, flags) but keeps progress bars and high-level status.

**Enrich stored messages (extract metadata from raw):**
```bash
# Extract ENVELOPE-like fields and RFC822 size from stored raw messages
docker compose run --rm ruby ./cli.rb enrich \
  --database core/data/your-email.sqlite3 \
  --address user@gmail.com
```
Notes:
- Enrich reads from the `encoded` raw message to populate: `rfc822_size`, `envelope_to`, `envelope_cc`, `envelope_bcc`, `envelope_reply_to`, `envelope_in_reply_to`, `envelope_references`.
- `internaldate` is captured during sync from IMAP and not modified by enrich.

**SQLite performance (WAL journaling):**
```bash
# Default: WAL is enabled (best write concurrency)
docker compose run --rm ruby ./cli.rb sync

# Disable WAL if needed (creates fewer sidecar files):
docker compose run --rm ruby ./cli.rb sync --no-sqlite-wal

# Or via env var (overrides the CLI default)
SQLITE_WAL=no docker compose run --rm ruby ./cli.rb sync
```
Rationale:
- WAL (Write-Ahead Logging) improves write throughput and reduces lock contention when many inserts occur.
- We also set a `busy_timeout` and `synchronous=NORMAL` for a good durability/performance balance when WAL is on.
Notes:
- WAL creates `-wal` and `-shm` sidecar files next to your `.sqlite3` file.
- Some networked filesystems don’t like WAL; if you see file locking issues, try `--no-sqlite-wal`.

Notes:
- CLI flags override environment variables when provided; if neither is set, defaults are 1 for both `--threads` and `--mailbox-threads`.
- Preflight opens up to `MAILBOX_THREADS` IMAP connections and performs a server‑diff: it queries the server for all UIDs in each mailbox and computes the set difference vs the local DB. Only missing UIDs are fetched.
- Message fetching still uses `--threads` per mailbox, processed sequentially after preflight. Messages are fetched in batches (default 100 UIDs per request, configurable via `--fetch-batch-size`/`FETCH_BATCH_SIZE`) to reduce IMAP round‑trips.
- Keep totals under Gmail’s ~15 connection limit. Example safe combos: `MAILBOX_THREADS=4` and `--threads 4` (preflight and fetch phases do not overlap).

**Purge old UIDVALIDITY generations (optional):**
```bash
# CLI flag (auto purge when a change is detected)
docker compose run --rm ruby ./cli.rb sync --purge-old-validity

# Environment variable (same behavior)
PURGE_OLD_VALIDITY=yes docker compose run --rm ruby ./cli.rb sync
```
Behavior:
- When Gmail rotates a mailbox’s `UIDVALIDITY`, rows from prior generations remain in the DB.
- With `--purge-old-validity` (or `PURGE_OLD_VALIDITY=yes`), NittyMail automatically deletes those older rows after a successful mailbox sync.
- Without the flag, you will be prompted to purge when a change is detected (skipped in non‑TTY/non‑interactive runs unless the flag is set).

⚠️ **IMPORTANT: Gmail IMAP Connection Limits**
- Gmail allows a **maximum of 15 simultaneous IMAP connections** per account
- Using too many threads may result in connection failures or temporary account blocking
- **Recommended thread counts:**
  - **1-4 threads**: Safe for most accounts
  - **5-8 threads**: Use with caution, monitor for errors
  - **9+ threads**: Not recommended, likely to hit Gmail limits
- If you encounter "Too many simultaneous connections" errors, reduce thread count
- For details, see: https://support.google.com/mail/answer/7126229

**Complete CLI example with all options (mail download only; embeddings via `embed` subcommand):**
```bash
docker compose run --rm ruby ./cli.rb sync \
  --address user@gmail.com \
  --password app-password \
  --database data/backup.sqlite3 \
  --mailbox-threads 4 \
  --threads 4 \
  --ignore-mailboxes "[Gmail]/*,Spam" \
  --retry-attempts 5 \
  --prune-missing \
  --auto-confirm \
  --purge-old-validity
```

**View available commands and options:**
```bash
docker compose run --rm ruby ./cli.rb help
docker compose run --rm ruby ./cli.rb help sync
```

**Verify sync results:**
```bash
sqlite3 core/data/your-email.sqlite3 'SELECT COUNT(*) FROM email;'
```

**Prune rows missing on server (optional):**
```bash
# CLI flag (delete rows whose UIDs are no longer present)
docker compose run --rm ruby ./cli.rb sync --prune-missing

# Environment variable (same behavior)
PRUNE_MISSING=yes docker compose run --rm ruby ./cli.rb sync
```
Behavior:
- When enabled, after a mailbox finishes processing successfully, NittyMail deletes rows whose UIDs are not present on the server for that mailbox and its current `UIDVALIDITY`.
- If pruning is disabled but candidates exist, NittyMail logs a message indicating the count and that no pruning will occur.
- If a mailbox aborts due to repeated connection errors, pruning for that mailbox is skipped.

## Behavior & Guarantees

- UID discovery uses a server‑diff (UID `1:*` vs local DB) to avoid gaps when resuming.
- `UIDVALIDITY` is required; if Gmail does not provide it during preflight or worker selection, the sync aborts with an error.
- If `UIDVALIDITY` changes between preflight and fetch, the sync aborts for that mailbox; rerun to proceed under the new generation.
- Mailboxes with zero missing UIDs (nothing to fetch) are skipped to save time and connections.
 - Read‑only IMAP: mailboxes are opened with `EXAMINE` and bodies are fetched with `BODY.PEEK[]`, so the sync does not mark messages as read or change flags.

### Preflight Output

Before fetching, NittyMail performs a per‑mailbox preflight that shows what will happen:

- Counts line with UIDVALIDITY, to_fetch (new UIDs on server), to_prune (rows present locally but not on server), and server/DB sizes.
- A preview of UIDs to be synced (first 5 shown), for example:
  - `uids to be synced: [101, 102, 103, 104, 105, ... (42 more uids)]`
- If pruning is disabled but candidates exist, an informational message like:
  - `prune candidates present: 42 (prune disabled; no pruning will be performed)`

### Retry and Abort Behavior

- Transient IMAP errors such as `SSL_read: unexpected eof while reading` (OpenSSL::SSL::SSLError), `IOError`, and `Errno::ECONNRESET` trigger a reconnect + retry with backoff.
- Retries are controlled by `--retry-attempts` (default: 3; `-1` means retry indefinitely, `0` disables retries).
- If a batch continues to fail and retries are exhausted, NittyMail aborts processing of the current mailbox and proceeds to the next; an informational message is logged.

### Local Deletions Are Re-synced

If you delete a row from the local `email` table for a message that still exists on the server under the current `UIDVALIDITY`, it will be re-synced on the next run.

Why this happens (mechanism):
- During preflight, NittyMail computes the set difference per mailbox: `server_uids - db_uids` for the current `UIDVALIDITY`.
- Any UID present on the server but missing in the local DB is considered “to fetch”, so the message is downloaded again.
- A unique constraint on `(mailbox, uid, uidvalidity)` prevents duplicate rows when rerunning.

When it will not be restored:
- The message was deleted on the server (its UID won’t be in `server_uids`).
- You delete a row from an older `UIDVALIDITY` generation; only the current generation’s UIDs are considered.
- The mailbox is ignored via `MAILBOX_IGNORE`/`--ignore-mailboxes`.

### Moves Between Mailboxes

Gmail can expose the same message in multiple mailboxes (labels). A move typically removes the label for the source mailbox and adds the label for the destination.

- Insert at destination: When a message appears under a new mailbox, it has a new UID for that mailbox. Preflight detects it as missing locally and inserts a new row.
- Remove from source: By default, NittyMail does not delete rows when UIDs disappear from a mailbox. The original row remains, so you may see two rows for the same message (use `x_gm_msgid` to correlate).
- Recommendation: ignore Trash/Spam to reduce duplicates, or dedupe by `x_gm_msgid` in queries.

Optional pruning:
- Enable `--prune-missing` (or `PRUNE_MISSING=yes`) to delete rows whose UIDs are no longer present on the server for the mailbox’s current UIDVALIDITY.
- Pruning runs after a mailbox finishes processing, based on the preflight diff; it skips pruning if the mailbox aborted due to repeated errors.

### Performance considerations

- Batched fetch: messages are fetched in batches (default size: 100 UIDs) using `UID FETCH` with `BODY.PEEK[]`, `FLAGS`, Gmail extensions, and `UID`. This significantly reduces round‑trips vs one‑by‑one fetch.
- Connection safety: using `EXAMINE` keeps sessions read‑only; `BODY.PEEK[]` avoids setting `\\Seen` on unread messages.

 - Server‑diff requires the server to return the full UID list for each mailbox; this is efficient server‑side but can be sizable over the wire for very large mailboxes (tens/hundreds of thousands of messages). Preflight is parallelized with `MAILBOX_THREADS` to mitigate wall‑clock time.

## Linting

Quick way (recommended):

```bash
./bin/lint
```

This installs gems if needed, runs `standardrb --fix .`, then verifies StandardRB and RuboCop in Docker.

Run linters inside Docker (do not use host Ruby):

```bash
# 1) Install gems in the container (once per Gemfile change)
docker compose run --rm ruby bundle

# 2) StandardRB (project style)
docker compose run --rm ruby bundle exec standardrb .

# 3) RuboCop (uses repo root config)
docker compose run --rm ruby bundle exec rubocop --config ../.rubocop.yml .

# Optional: auto-fix straightforward issues
docker compose run --rm ruby bundle exec standardrb --fix .
```

Notes:
- Container working directory is `/app/core`, hence RuboCop uses `--config ../.rubocop.yml`.
- Both linters must pass with zero offenses before commits/PRs.
- If a linter exits non‑zero without obvious output, re‑run; StandardRB may only signal failures via exit status. Use `--fix` where safe, then re‑run.

## Architecture Overview

Core modules live under `core/lib/nittymail` to keep `sync.rb` lean and focused on orchestration:

- `util.rb`: encoding (`safe_utf8`), JSON (`safe_json`), Mail parsing (`parse_mail_safely`), and subject extraction.
- `logging.rb`: small helpers for log formatting (e.g., `format_uids_preview`).
- `gmail_patch.rb`: applies Gmail extensions to Ruby's `Net::IMAP` response parser.
- `db.rb`: database schema bootstrap (`ensure_schema!`), prepared insert builder, and pruning helpers.
- `preflight.rb`: computes per‑mailbox diffs (to_fetch, db_only) and sizes.

`sync.rb` ties these together: preflights mailboxes, processes UIDs in batches with retry/backoff, writes via a single writer thread, and optionally prunes rows missing on the server.

### Vector Search (sqlite-vec)

We support vector embeddings using sqlite-vec via the official Ruby gem. This enables fast, local semantic search over message content. The full guide moved to [docs/vector-embeddings.md](../docs/vector-embeddings.md).

References:
- Ruby docs: https://alexgarcia.xyz/sqlite-vec/ruby.html
- Minimal example: https://github.com/asg017/sqlite-vec/blob/main/examples/simple-ruby/demo.rb

Requirements and defaults:
- The sqlite-vec Ruby gem is bundled; the extension is loaded by the gem at runtime.
- `SQLITE_VEC_DIMENSION`: embedding dimension for the virtual table (default: `1024`).
- Default embedding model for Ollama: `mxbai-embed-large` (English, high quality, 1024‑dim). Multilingual alternative: `bge-m3` (also 1024‑dim).

What the app creates on startup:
- `email_vec` (virtual table): `CREATE VIRTUAL TABLE IF NOT EXISTS email_vec USING vec0(embedding float[DIM])`
- `email_vec_meta`: maps `email_vec.rowid` to `email.id` with metadata (`item_type`, `model`, `dimension`, `created_at`).

If the sqlite-vec extension cannot be loaded via the gem helper, the process aborts (no fallback schema is created).

Choosing a dimension and model:
- The vec table’s dimension is fixed at creation time. Set `SQLITE_VEC_DIMENSION` (default 1024) before the first run, and keep it consistent with your embedding model.
- Recommended default: `mxbai-embed-large` (1024 dims). To try others, create separate vec tables per dimension or re‑create the table to match the new dimension.

Quick start with Ollama (verify dimension):
```bash
# Pull the default high-quality embedding model (English)
ollama pull mxbai-embed-large

# Verify the output embedding dimension
curl -s http://localhost:11434/api/embeddings \
  -d '{"model":"mxbai-embed-large","prompt":"hello world"}' | jq '.embedding | length'

# Ensure vec table dimension matches your model (1024 recommended)
export SQLITE_VEC_DIMENSION=1024
```

Ruby usage overview (from the sqlite-vec docs):
```ruby
require "sqlite3"
require "sqlite_vec"

db = SQLite3::Database.new(":memory:")
db.enable_load_extension(true)
SqliteVec.load(db)
db.enable_load_extension(false)

db.execute("CREATE VIRTUAL TABLE vec_items USING vec0(embedding float[4])")

# Insert: pack float32s into a BLOB
embedding = [0.1, 0.1, 0.1, 0.1]
db.execute("INSERT INTO vec_items(rowid, embedding) VALUES (?, ?)", [1, embedding.pack("f*")])

# Query: use MATCH with a packed query vector
query = [0.1, 0.1, 0.1, 0.1]
rows = db.execute(<<~SQL, [query.pack("f*")])
  SELECT rowid, distance
  FROM vec_items
  WHERE embedding MATCH ?
  ORDER BY distance
  LIMIT 3
SQL
```

NittyMail specifics (Sequel + sqlite-vec):
- We load sqlite-vec using the gem helper against the underlying SQLite3 connection that Sequel manages. No manual extension path is needed.
- Virtual table: `email_vec(embedding float[DIM])` with DIM from `SQLITE_VEC_DIMENSION`.
- Metadata table: `email_vec_meta(vec_rowid, email_id, item_type, model, dimension, created_at)`.
- Insert embeddings as packed float32 BLOBs. Use transactions for batching.

Insert an embedding and link it to an email row:
```ruby
require "sequel"
require "sqlite3"

db = Sequel.sqlite("data/your-email.sqlite3")
NittyMail::DB.ensure_schema!(db)

email_id = 123                         # existing row in the email table
vector   = some_floats                 # Array(Float), length must equal DIM (e.g., 1024)
packed   = vector.pack("f*")           # pack as float32 (native endianness)
model    = ENV.fetch("EMBEDDING_MODEL", "mxbai-embed-large")
item     = "body"                      # e.g., body, subject, snippet
dimension = (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i

# Insert into vec table and get the rowid, then insert metadata
vec_rowid = nil
db.transaction do
  db.synchronize do |conn|
    conn.execute("INSERT INTO email_vec(embedding) VALUES (?)", SQLite3::Blob.new(packed))
    vec_rowid = conn.last_insert_row_id
  end
  db[:email_vec_meta].insert(vec_rowid:, email_id:, item_type: item, model:, dimension:)
end
```

Top‑K search for similar messages (join with metadata):
```ruby
require "sequel"
require "sqlite3"

db = Sequel.sqlite("data/your-email.sqlite3")
query = make_query_vector(...)          # Array(Float) with DIM elements
blob  = SQLite3::Blob.new(query.pack("f*"))

rows = nil
db.synchronize do |conn|
  rows = conn.execute(<<~SQL, blob)
    SELECT m.email_id, v.rowid AS vec_rowid, v.distance
    FROM email_vec v
    JOIN email_vec_meta m ON m.vec_rowid = v.rowid
    WHERE v.embedding MATCH ?
    ORDER BY v.distance
    LIMIT 10
  SQL
end
pp rows
```

Helper methods (recommended):
```ruby
require "sequel"
require "sqlite3"
require_relative "lib/nittymail/db"

db = Sequel.sqlite("data/your-email.sqlite3")

# Prepare your vector (length must equal SQLITE_VEC_DIMENSION, default 1024)
vector = embed_text_with_ollama("some text to embed") # => Array(Float)

# Insert a new embedding and link to email_id
vec_rowid = NittyMail::DB.insert_email_embedding!(
  db,
  email_id: 123,
  vector: vector,
  item_type: "body",                      # or "subject", "snippet"
  model: ENV.fetch("EMBEDDING_MODEL", "mxbai-embed-large"),
  dimension: (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i
)

# Or upsert by (email_id, item_type, model)
vec_rowid = NittyMail::DB.upsert_email_embedding!(
  db,
  email_id: 123,
  vector: vector,
  item_type: "body",
  model: ENV.fetch("EMBEDDING_MODEL", "mxbai-embed-large"),
  dimension: (ENV["SQLITE_VEC_DIMENSION"] || "1024").to_i
)
```

Notes:
- The helpers validate vector length and pack to float32 BLOBs.
- They ensure the sqlite-vec virtual table and metadata table exist for the configured dimension.

Embeddings are generated via the `embed` subcommand (sync does not embed):
```bash
# Ensure OLLAMA_HOST points to your server
DATABASE=data/your.sqlite3 ADDRESS=user@gmail.com OLLAMA_HOST=http://localhost:11434 \
  docker compose run --rm ruby ./cli.rb embed
```

See `docs/vector-embeddings.md` for details on configuration, schema, data flow, and querying.

Backfill embeddings for existing emails (examples):
```bash
# Or pass flags explicitly
docker compose run --rm ruby ./cli.rb embed \
  --database data/your.sqlite3 \
  --ollama-host http://localhost:11434 \
  --item-types subject,body
```

Tip: Use `--batch-size 1000` (default) to control how many embedding jobs are kept in-flight. Increase for higher throughput or reduce to limit memory usage.

**Understanding the embed progress bar:**
```
embed: |████████████████████| 45% (15420/34200) job=998 write=5 [2m15s]
```
- **`45% (15420/34200)`**: 15,420 embeddings completed out of 34,200 total estimated jobs
- **`job=998`**: 998 embedding jobs queued and waiting to be processed by worker threads
- **`write=5`**: 5 completed embeddings waiting to be written to the database
- **`[2m15s]`**: Estimated time remaining

Queue indicators:
- **High job queue** (near batch-size): Worker threads are busy, Ollama is keeping up
- **High write queue**: Database writes may be slower than embedding generation
- **Both queues low**: System is keeping up well, no bottlenecks

Notes and tips:
- The `embedding` column expects a packed float32 BLOB (`Array#pack("f*")`).
- The array length must exactly match the dimension used in `CREATE VIRTUAL TABLE`.
- Smaller `distance` means a closer match. Use `LIMIT` to constrain results.
- Wrap mass inserts in a transaction for better performance.
- See the official docs and example for more patterns:
  - Docs: https://alexgarcia.xyz/sqlite-vec/ruby.html
  - Example: https://github.com/asg017/sqlite-vec/blob/main/examples/simple-ruby/demo.rb

## Troubleshooting

### Gmail Connection Issues

**"Too many simultaneous connections" errors:**
- Gmail limits accounts to **15 simultaneous IMAP connections**
- Reduce the `--threads` parameter (try 1-4 threads)
- Wait a few minutes before retrying if temporarily blocked
- Reference: https://support.google.com/mail/answer/7126229

**Authentication failures:**
- Ensure IMAP is enabled in Gmail settings
- Use App Passwords for 2FA-enabled accounts
- Verify your email and password are correct
- Check for typos in your `.env` file

**Database corruption errors:**
- Stop any running sync processes
- Backup your existing database: `cp data/your-email.sqlite3 data/backup.sqlite3`
- Remove the corrupted file to start fresh: `rm data/your-email.sqlite3`
- The sync will recreate the database automatically

**Performance optimization:**
- Start with 1 thread for initial sync, then increase gradually
- Monitor system resources (CPU, memory, network)
- Large mailboxes may take several hours to complete

### Messages without a Date header

Some messages in the wild have a missing or invalid `Date:` header. When the Mail gem cannot parse a date, NittyMail does not fail the sync. Instead, it sets the `date` field to `NULL` for that record and continues.

- Behavior: records with unparsable or absent dates are inserted with `date = NULL`.
- Rationale: avoid guessing dates from other headers; prevents incorrect metadata.
- Inspect affected rows:
  ```bash
  sqlite3 core/data/your-email.sqlite3 "SELECT COUNT(*) FROM email WHERE date IS NULL;"
  ```
  You can later derive a date from other headers (e.g., `Received`) or use the `internaldate` field downstream if needed.

## Contributing

Bug reports and pull requests are welcome on GitHub at <https://github.com/parasquid/nittymail/issues>

## Gmail IMAP Extensions

This project uses Gmail-specific IMAP attributes for richer metadata. See [docs/gmail-imap-extensions.md](../docs/gmail-imap-extensions.md) for details on X-GM-LABELS, X-GM-MSGID, and X-GM-THRID.

## License

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
