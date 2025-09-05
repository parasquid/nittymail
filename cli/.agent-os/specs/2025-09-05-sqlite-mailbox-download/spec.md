# Spec Requirements Document

> Spec: sqlite-mailbox-download
> Created: 2025-09-05

## Overview

Replace Chroma-based storage with a local SQLite3 database (via ActiveRecord) for `cli mailbox download`, preserving every message in raw RFC822 form while also storing plain_text and markdown columns and indexing INTERNALDATE for fast lookups.

## User Stories

### Preserve Complete Mail Archive

As a user, I want to download and store my Gmail messages locally in SQLite, including the full raw RFC822 content, so that I have a complete, lossless archive that I fully control.

Detailed workflow: User runs `cli mailbox download` with address/password; the tool connects over IMAP, discovers UIDs, fetches messages in batches, and writes each email in a single `emails` table row with raw, plain_text, markdown, subject, and INTERNALDATE recorded and indexed.

### Searchable Text Without Embeddings

As a user, I want plain text and markdown columns saved for each message, so that I can quickly filter, search by subject/text, and preview content without any vector database or embeddings.

Detailed workflow: During write, the system parses the RFC822 message to extract subject and produce normalized `plain_text` and a simple `markdown` representation, storing them alongside the raw column.

### Simple, Fast, Resumable Download

As a user, I want the download command to be simple, fast, and resumable, so that repeated runs only fetch missing items and I see clear progress without complicated Chroma/LLM steps.

Detailed workflow: The tool compares server UIDs with the database’s composite key (`address`, `mailbox`, `uidvalidity`, `uid`), fetches only missing messages, uses batched inserts within transactions, and resumes cleanly on re-run.

## Spec Scope

1. **SQLite Storage via ActiveRecord** - Introduce ActiveRecord with SQLite3 adapter and configure a single database file; remove any Chroma usage from `cli mailbox download` path.
2. **Email Schema** - Create an `emails` table with columns: address, mailbox, uidvalidity, uid, subject, internaldate (datetime), internaldate_epoch (integer), rfc822_size, from_email, to_emails, cc_emails, bcc_emails, labels_json, raw (blob), plain_text (text), markdown (text), created_at, updated_at.
3. **Indexes & Keys** - Unique index on (`address`, `mailbox`, `uidvalidity`, `uid`); index on `internaldate_epoch`; optional indexes on `subject` and `address`.
4. **Downloader Simplification** - Streamline `cli mailbox download` flags to IMAP-related controls only (address/password/only/ignore/threads/batch-size) and database path; no Chroma/embedding flags.
5. **Parsing Pipeline** - Use `mail` gem to parse RFC822, extract subject and headers, derive `plain_text` and basic `markdown` views; do not mutate raw; ensure deterministic, idempotent parsing.
6. **Performance & Reliability** - Use WAL mode, batched inserts inside transactions, prepared statements, retry IMAP batches; clear progress events; graceful interrupt with safe checkpoints.
7. **Tests & Linting** - Add specs for schema, idempotent writes, parsing, and UID de-duplication; keep Standard/RuboCop clean.

## Out of Scope

- Vector embeddings or semantic search (Chroma/sqlite-vec).
- Natural-language querying, LLM tooling, or Ollama integration.
- Cross-DB support beyond SQLite3.
- GUI or non-CLI interfaces.

## Expected Deliverable

1. Running `cli mailbox download` writes messages into SQLite with populated `raw`, `plain_text`, `markdown`, `subject`, and `internaldate`/`internaldate_epoch`, enforcing uniqueness by (`address`,`mailbox`,`uidvalidity`,`uid`).
2. The command is resumable and faster than current Chroma-based path due to batched transactions and WAL; basic RSpec suite passes and linting is clean.
