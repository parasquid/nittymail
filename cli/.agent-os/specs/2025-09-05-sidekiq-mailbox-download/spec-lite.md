# Spec Summary (Lite)

Add an optional Redis-backed job mode (Active Job with Sidekiq adapter) for `mailbox download` that parallelizes IMAP fetches via multiple workers while a single writer worker safely persists to SQLite. Preserve current single-process behavior under a `--no-jobs` flag, with job mode opt-in using `--jobs`. The CLI enqueues work and polls Redis counters to render the progress bar, preferring Active Job–level APIs rather than Sidekiq-specific queue inspection; workers exchange only metadata and file paths, storing raw RFC822 artifacts in a shared `job-data` folder.
