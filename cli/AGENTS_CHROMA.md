# Chroma Client (chroma-db gem) — Agent Guide

This guide explains how AI agents should use the `chroma-db` Ruby client in this repo to store and read email documents, including real-world pitfalls we hit and how to avoid them.

## Overview

- Purpose: Store raw email documents in Chroma and avoid re-uploading duplicates.
- Gem: `chroma-db` (works with Chroma 0.4.24+ APIs).
- Service: Docker Compose service `chroma` on `http://chroma:8000`.

## Setup & Compatibility

- Start the DB: `docker compose up -d chroma`.
- Version: Pin to a compatible image (recommended 0.5.x). In `cli/docker-compose.yml`:
  - `image: chromadb/chroma:0.5.4`
- Host from containers: Use `http://chroma:8000` (not `localhost`).
- Defaults: The gem builds URLs as `#{connect_host}/#{api_base}/#{api_version}` → usually `http://chroma:8000/api/v1`.
- If your server exposes different paths, override:
  - Ruby: `Chroma.api_base = ""` and/or `Chroma.api_version = ""`
  - CLI flags: `--chroma_api_base`, `--chroma_api_version`

## Configure Client

```ruby
require "chroma-db"

# Minimum config
Chroma.connect_host = ENV["NITTYMAIL_CHROMA_HOST"] || "http://chroma:8000"

# Optional: logs for debugging (0=none, 1=info, 2=debug)
Chroma.log_level = Chroma::LEVEL_ERROR

# Optional: Hosted Chroma
# Chroma.api_key = ENV["CHROMA_API_KEY"]
# Chroma.tenant = "default_tenant"
# Chroma.database = "default_database"

# Optional overrides (if your server differs):
# Chroma.api_base = "api"
# Chroma.api_version = "v1"
```

## Collections (naming constraints)

Chroma requires collection names that:
- Are 3–63 chars, start and end with an alphanumeric character.
- Only contain letters/digits/underscore/hyphen.
- No consecutive periods; not a valid IPv4 address.

Use a deterministic collection name so runs converge. Default scheme here: `"nittymail-<address>-<mailbox>"` then sanitize.

```ruby
collection_name = "nittymail-#{address}-#{mailbox}"
collection_name = collection_name.downcase
  .gsub(/[^a-z0-9_-]+/, '-') # replace invalid with '-'
  .gsub(/-+/, '-')           # collapse dashes
  .gsub(/^[-_]+|[-_]+$/, '') # trim non-alnum edges
collection_name = collection_name[0,63]
collection_name = 'nm' if collection_name.nil? || collection_name.empty?

collection = Chroma::Resources::Collection.get_or_create(collection_name)
```

If you pass a custom name, ensure it meets these rules or Chroma raises `Chroma::InvalidRequestError`.

## Deduplication (IDs)

- Use `"#{uidvalidity}:#{uid}"` as the document ID.
- This aligns with IMAP semantics and prevents re-uploading the same message across syncs.

## Listing Existing Documents (paging)

Page through results to find existing IDs for the current UIDVALIDITY.

```ruby
existing = []
page = 1
page_size = 1000
prefix = "#{uidvalidity}:"

loop do
  embeddings = collection.get(page: page, page_size: page_size)
  ids = embeddings.map(&:id)
  break if ids.empty?
  existing.concat(ids.grep(/^#{Regexp.escape(prefix)}/))
  break if ids.size < page_size
  page += 1
end

existing_uids = existing.map { |id| id.split(":", 2)[1].to_i }
```

Tip: You can also filter by metadata with `where:` (server-dependent), e.g. `where: { uidvalidity: 2 }` to reduce paging.

## Uploading Documents (batched)

```ruby
to_add_ids = ["2:123", "2:124"]
to_add_docs = ["raw email 1...", "raw email 2..."]
to_add_meta = [
  {address: address, mailbox: mbox, uidvalidity: 2, uid: 123},
  {address: address, mailbox: mbox, uidvalidity: 2, uid: 124}
]

batch_size = 100
to_add_ids.each_slice(batch_size)
  .zip(to_add_docs.each_slice(batch_size), to_add_meta.each_slice(batch_size))
  .each do |id_chunk, doc_chunk, meta_chunk|
    embeddings = id_chunk.each_with_index.map do |idv, idx|
      Chroma::Resources::Embedding.new(id: idv, document: doc_chunk[idx], metadata: meta_chunk[idx])
    end
    collection.add(embeddings) # true or raises
  end
```

Notes:
- We pass documents + metadata without local embedding vectors.
- Ensure your Chroma server is configured with a default embedding function to compute embeddings server-side, or the add call may fail.

## Quick Health Checks

```ruby
Chroma::Resources::Database.version     # => {"version"=>"0.x.y"}
Chroma::Resources::Database.heartbeat   # => {"nanosecond heartbeat"=>...}
Chroma::Resources::Collection.list      # => [#<Collection ...>, ...]
```

From inside the CLI container:
- `curl -i http://chroma:8000/api/v1/version`

## Troubleshooting (what we encountered)

- Connection refused to localhost:
  - Use the Docker service name `http://chroma:8000` inside containers, not `http://localhost:8000`.

- 404/405 on endpoints:
  - Pin a compatible image: `chromadb/chroma:0.5.4`.
  - If your server uses non-standard paths, set `Chroma.api_base`/`Chroma.api_version` (or CLI flags) appropriately.
  - Verify health: `curl -i http://chroma:8000/api/v1/version`.

- Invalid collection name (Chroma::InvalidRequestError):
  - Sanitize names as shown above (no `:`, `@`, `.`, spaces). Length 3–63, start/end alnum.

- Generic API errors (Chroma::APIError):
  - Enable logs: `CHROMA_LOG=1` or `Chroma.log_level = Chroma::LEVEL_INFO`.
  - Inspect container logs: `docker compose logs -f chroma`.
  - If using hosted Chroma, set `Chroma.api_key`.

## Integration Points in this Repo

- CLI command `mailbox download`:
  - Reads `NITTYMAIL_CHROMA_HOST` or `--chroma_host`.
  - Optional: `--chroma_api_base`, `--chroma_api_version`.
  - Creates/loads a collection per mailbox and uploads new emails in batches.
  - Uses `"#{uidvalidity}:#{uid}"` IDs for dedup.
