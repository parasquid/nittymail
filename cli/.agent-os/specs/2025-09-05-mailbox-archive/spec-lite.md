# Spec Summary (Lite)

Add a new `cli mailbox archive` command that downloads all mail from a mailbox as raw RFC822 files without any parsing or database writes. Files are saved as `<uid>.eml` under `cli/archives/<address>/<mailbox>/<uidvalidity>/`. The command is resumable (skips existing files), shows a progress bar, and defaults to a jobs mode (Active Job with Sidekiq adapter) while supporting `--no-jobs` to run in single-process mode without Redis. The archives folder contains a `.keep` file so it is tracked; all other archive files are gitignored by default to prevent accidental commits.
