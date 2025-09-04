# Chroma Reference (CLI)

This document explains how the CLI integrates with Chroma (via the `chroma-db` Ruby gem): setup, collection conventions, batching, concurrency, and troubleshooting.

## Setup & Compatibility

- Service: Docker Compose service `chroma` at `http://chroma:8000`.
- Image: `chromadb/chroma:0.5.x` (Compose pins to `0.5.4`).
- Client: `chroma-db` Ruby gem.

## Configure Client (canonical helper)

Always use the shared helper to configure the client and get a collection:

```ruby
require_relative "../utils/db"

collection = NittyMail::DB.chroma_collection(collection_name)

# Env defaults:
# - NITTYMAIL_CHROMA_HOST (default http://chroma:8000)
# - NITTYMAIL_CHROMA_API_BASE (optional)
# - NITTYMAIL_CHROMA_API_VERSION (optional)
```

## Collections (naming constraints)

Chroma requires collection names that:
- Are 3–63 chars, start and end with an alphanumeric character.
- Only contain letters/digits/underscore/hyphen.
- No consecutive periods; not a valid IPv4 address.

The CLI derives a deterministic collection name: `nittymail-<address>-<mailbox>` and sanitizes it. If you supply a custom name, ensure it meets these rules or Chroma raises `Chroma::InvalidRequestError`.

## Deduplication (IDs)

- Use `"#{uidvalidity}:#{uid}"` as the document ID.
- Aligns with IMAP semantics and prevents re-uploading the same message across syncs.

## Listing Existing Documents (paging)

Prefer server-side filtering by `uidvalidity` when available; otherwise filter by ID prefix.

```ruby
existing = []
page = 1
page_size = 1000

loop do
  embeddings = collection.get(page: page, page_size: page_size, where: { uidvalidity: uidvalidity })
  ids = embeddings.map(&:id)
  break if ids.empty?
  existing.concat(ids)
  break if ids.size < page_size
  page += 1
end

existing_uids = existing.map { |id| id.split(":", 2)[1].to_i }
```

## Uploading Documents (batched)

```ruby
to_add_ids = ["2:123", "2:124"]
to_add_docs = ["raw email 1...", "raw email 2..."]
to_add_meta = [
  {address: address, mailbox: mailbox, uidvalidity: 2, uid: 123, internaldate_epoch: 1_724_000_000},
  {address: address, mailbox: mailbox, uidvalidity: 2, uid: 124, internaldate_epoch: 1_724_000_123}
]

batch_size = 100
to_add_ids.each_slice(batch_size)
  .zip(to_add_docs.each_slice(batch_size), to_add_meta.each_slice(batch_size))
  .each do |id_batch, doc_batch, meta_batch|
    embeddings = id_batch.each_with_index.map do |idv, idx|
      Chroma::Resources::Embedding.new(id: idv, document: doc_batch[idx], metadata: meta_batch[idx])
    end
    collection.add(embeddings)
  end
```

Notes:
- We pass documents + metadata without local embedding vectors.
- Ensure your Chroma server is configured with a default embedding function, or the add call may fail.

## Metadata Schema

Each uploaded embedding includes a `metadata` hash with mailbox and message fields used by CLI tools:

- address: Gmail address (string)
- mailbox: IMAP mailbox name (string)
- uidvalidity: IMAP UIDVALIDITY for the mailbox (integer)
- uid: IMAP UID for the message within the UIDVALIDITY (integer)
- internaldate_epoch: Server-reported INTERNALDATE as Unix epoch seconds (integer)

These fields enable fast existence checks, “latest” queries, and stats without IMAP access. Keep types stable to preserve filter performance.


## Concurrency & Tuning

- Producer–consumer model:
  - Producer fetches IMAP messages in slices and enqueues chunks.
  - Multiple consumers upload chunks concurrently with `collection.add`.
- Controls (CLI flags):
  - `--upload-threads`: number of parallel upload workers (recommend 2–4).
  - `--fetch-threads`: number of parallel IMAP fetchers (recommend 2–4).
  - `--max-fetch-size`: IMAP fetch slice size (defaults to `Settings#max_fetch_size`).
  - `--upload-batch-size`: upload chunk size per HTTP request (typical 100–500).
- Progress: `ruby-progressbar` shows %/counts/ETA; updates as chunks complete.
- Interrupts: first Ctrl-C stops after current chunk; second Ctrl-C forces exit.

## Quick Health Checks

```ruby
Chroma::Resources::Database.version     # => {"version"=>"0.x.y"}
Chroma::Resources::Database.heartbeat   # => {"nanosecond heartbeat"=>...}
Chroma::Resources::Collection.list      # => [#<Collection ...>, ...]
```

From inside the CLI container:
- `curl -i http://chroma:8000/api/v1/version`

## Troubleshooting

- Connection refused to localhost: use `http://chroma:8000` inside containers.
- 404/405 on endpoints: pin a compatible image, and set `Chroma.api_base`/`Chroma.api_version` if your server differs.
- Invalid collection name (Chroma::InvalidRequestError): sanitize names (no `:`, `@`, `.`, spaces); length 3–63; start/end alnum.
- Generic API errors (Chroma::APIError): enable logs (`CHROMA_LOG=1`), inspect container logs (`docker compose logs -f chroma`).

## Integration Points

- CLI command `mailbox download`:
  - Reads `NITTYMAIL_CHROMA_HOST` (and optional `NITTYMAIL_CHROMA_API_BASE`/`NITTYMAIL_CHROMA_API_VERSION`).
  - Creates/loads a collection per mailbox and uploads new emails in batches.
  - Uses `"#{uidvalidity}:#{uid}"` IDs for dedup.
  - Stores `internaldate_epoch` (IMAP INTERNALDATE) for fast latest queries.

- CLI command `db latest`:
  - Finds the newest email using `internaldate_epoch` via binary search + tight fetch.
  - Provide `--uidvalidity` or it will attempt to infer and list options when ambiguous.

