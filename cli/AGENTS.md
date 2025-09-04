# Agent Guide (CLI)

This guide covers how AI agents should work within the CLI folder: naming style, how to use the Chroma helper, and concurrency controls.

## Style Notes

- Prefer concise but descriptive variable names; avoid cryptic one-letter names in non-trivial scopes.
- Examples: `mailbox_client` (not `mb`), `fetch_response` (not `fr`), `doc_ids`/`documents`/`metadata_list` (not `ids`/`docs`/`metas`).
- Use `until interrupted` instead of `loop do` + `break if interrupted` when expressing interrupt-aware loops.
- Rescue specific exceptions; log actionable context; avoid swallowing errors unless explicitly justified.

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

