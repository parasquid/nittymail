# Spec Summary (Lite)

Implement a SQLite3-backed `cli mailbox download` that stores each email’s raw RFC822 plus parsed `plain_text` and `markdown` columns, with `INTERNALDATE` persisted and indexed for fast time-based lookups. Remove Chroma and any embedding concerns, focusing solely on a simple, fast, resumable downloader using ActiveRecord for persistence.
