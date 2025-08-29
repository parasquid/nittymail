# Vector Embeddings (sqlite-vec + Ollama)

This document explains how NittyMail generates and stores embeddings for emails using the sqlite-vec Ruby gem and an Ollama server.

Quick links:
- Ruby sqlite-vec docs: https://alexgarcia.xyz/sqlite-vec/ruby.html
- Minimal Ruby example: https://github.com/asg017/sqlite-vec/blob/main/examples/simple-ruby/demo.rb

## Overview

- Storage: sqlite-vec virtual table `email_vec(embedding float[DIM])` and metadata table `email_vec_meta` linking vectors to rows in `email`.
- Generation: vectors are fetched from an Ollama server via `POST /api/embeddings`.
- Scope: by default we embed the subject and body for each message inserted during a sync when embeddings are enabled.

## Requirements

- sqlite-vec Ruby gem (bundled in this repo). NittyMail loads the extension via `SqliteVec.load(conn)`.
- An Ollama server running an embedding model (default: `mxbai-embed-large`).
- The SQLite vec table dimension must match the model’s output dimension (default: 1024).

## Configuration

- `EMBEDDING_MODEL`: embedding model name for Ollama (default: `mxbai-embed-large`).
- `SQLITE_VEC_DIMENSION`: integer dimension (default: `1024`).
- `OLLAMA_HOST`: base URL of the Ollama server (e.g., `http://localhost:11434`). When set, embeddings are enabled for the sync.

CLI flag (optional):
- `--ollama-host http://localhost:11434` (overrides `OLLAMA_HOST`).

Example `.env` settings:
```
EMBEDDING_MODEL=mxbai-embed-large
SQLITE_VEC_DIMENSION=1024
OLLAMA_HOST=http://localhost:11434
```

## What gets embedded

- Subject: the sanitized subject line.
- Body: best-effort plain text body.
  - Prefers `text/plain` content when present.
  - If only HTML is available, a basic tag strip is applied.

For each embedded field, a row is inserted (or upserted) into `email_vec` and an entry into `email_vec_meta` with:
- `email_id`: link to the `email` table row
- `item_type`: `subject` or `body`
- `model`: embedding model name
- `dimension`: vector dimension
- `created_at`: timestamp

## Running a sync with embeddings enabled

1) Start or ensure Ollama is running and has the model you want:
```bash
ollama pull mxbai-embed-large
```

2) Run the sync with `OLLAMA_HOST` set (or `--ollama-host`):
```bash
docker compose run --rm \
  -e OLLAMA_HOST=http://localhost:11434 \
  ruby ./cli.rb sync --database data/your.sqlite3 --address user@gmail.com --password app_pass
```

3) Verify vectors were stored:
```bash
sqlite3 core/data/your.sqlite3 '\n.mode box\n.headers on\nSELECT * FROM email_vec_meta LIMIT 5;'
```

## Querying for similar messages

Use `MATCH` against the vec table with a packed float32 query vector, joining metadata to map back to emails. See README for a complete example, or adapt this pattern:
```ruby
qblob = SQLite3::Blob.new(query_vector.pack("f*"))
rows = db.synchronize { |conn| conn.execute(<<~SQL, qblob)
  SELECT m.email_id, v.rowid AS vec_rowid, v.distance
  FROM email_vec v
  JOIN email_vec_meta m ON m.vec_rowid = v.rowid
  WHERE v.embedding MATCH ?
  ORDER BY v.distance
  LIMIT 10
SQL
}
```

## Notes & Tips

- Dimension lock-in: the vec table’s dimension is fixed at creation; keep `SQLITE_VEC_DIMENSION` consistent with your model.
- Performance: wrap inserts in transactions. WAL mode is enabled by default for better write throughput.
- Errors: if Ollama returns an error or the embedding dimension doesn’t match, the run logs the error. With `--strict-errors`, the sync aborts on such errors.
- References:
  - sqlite-vec Ruby docs: https://alexgarcia.xyz/sqlite-vec/ruby.html
  - Demo script: https://github.com/asg017/sqlite-vec/blob/main/examples/simple-ruby/demo.rb

