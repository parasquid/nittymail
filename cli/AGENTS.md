# Agent Guide (CLI)

This guide covers how AI agents should work within the CLI folder: naming style, how to use the Chroma helper, and concurrency controls.

## Style Notes

- Prefer concise but descriptive variable names; avoid cryptic one-letter names in non-trivial scopes.
- Examples: `mailbox_client` (not `mb`), `fetch_response` (not `fr`), `doc_ids`/`documents`/`metadata_list` (not `ids`/`docs`/`metas`).
- Use `until interrupted` instead of `loop do` + `break if interrupted` when expressing interrupt-aware loops.
- Rescue specific exceptions; log actionable context; avoid swallowing errors unless explicitly justified.
- Do not swallow exceptions silently. If you skip or fall back, log a concise warning with the error class/message and enough identifiers (e.g., `uidvalidity`, `uid`, id range) to triage. Only suppress when there is a strong reason and you have an alternate path.
- **Hash Shorthand**: Use Ruby hash shorthand syntax when the key matches the variable name (e.g., `{foo:}` instead of `{foo: foo}`).


## Chroma Client (canonical helper)

Always configure Chroma through the shared helper and then use the returned collection.

```ruby
require_relative "utils/db"

collection = NittyMail::DB.chroma_collection(collection_name)
# Env defaults read by the helper:
# - NITTYMAIL_CHROMA_HOST (default http://chroma:8000)
# - NITTYMAIL_CHROMA_API_BASE (optional)
# - NITTYMAIL_CHROMA_API_VERSION (optional)
```

### Chroma Docs

- See `docs/chroma.md` for full Chroma details: metadata schema, naming rules, deduplication IDs, paging and batching examples, search across multiple embeddings, tuning/backpressure, health checks, and troubleshooting.

### IDs and Metadata (quick rules)

- Use `"#{uidvalidity}:#{uid}"` as the document ID to align with IMAP semantics and deduplicate across syncs.
- Store multiple representations per message with `item_type` metadata: `raw`, `plain_text`, `markdown`, `subject`.
- Keep raw RFC822 pristine; normalize only non-raw variants on upload.
- Include mailbox fields in metadata: `address`, `mailbox`, `uidvalidity`, `uid`, `internaldate_epoch`, `from_email`, `rfc822_size`, `labels`, `item_type`.

## Concurrency & Tuning

- Producer–consumer pipeline:
  - Fetchers enqueue batches; upload workers call `collection.add` in parallel.
- CLI flags:
  - `--fetch-threads`: number of parallel IMAP fetchers (recommend 2–4).
  - `--upload-threads`: number of parallel upload workers (recommend 2–4).
  - `--max-fetch-size`: IMAP fetch slice size (defaults to `Settings#max_fetch_size`).
  - `--upload-batch-size`: upload chunk size per HTTP request (typical 100–500).
- Progress and interrupts:
  - `ruby-progressbar` shows %/counts/ETA.
  - First Ctrl-C: graceful stop; second Ctrl-C: force exit.

## Persistence (Chroma)

- Data persists under `cli/chroma-data` bind-mounted into the container.
- See `docs/chroma.md` for full Chroma details and troubleshooting.

## Lint Before Committing

- Run StandardRB auto-fix and RuboCop inside Docker from the `cli/` folder:
  - `docker compose run --rm cli bundle install`
  - `docker compose run --rm cli bundle exec standardrb --fix`
  - `docker compose run --rm cli bundle exec rubocop -A`
- Ensure no offenses remain before committing.

## Tests

- Write specs in rspec-given style for readability.
- Require `rspec/given` via `spec/spec_helper.rb` (already set up here).
- Run specs from `cli/` via Docker:
  - `docker compose run --rm cli bundle exec rspec -fd -b`
