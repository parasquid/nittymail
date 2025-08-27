# NittyMail Core

This folder contains some common functionality, among which is a simple syncing script that will download all messages in a Gmail account to an sqlite3 database.

## Usage

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

**Complete CLI example with all options:**
```bash
docker compose run --rm ruby ./cli.rb sync \
  --address user@gmail.com \
  --password app-password \
  --database data/backup.sqlite3 \
  --mailbox-threads 4 \
  --threads 4 \
  --ignore-mailboxes "[Gmail]/*,Spam" \
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

## Behavior & Guarantees

- UID discovery uses a server‑diff (UID `1:*` vs local DB) to avoid gaps when resuming.
- `UIDVALIDITY` is required; if Gmail does not provide it during preflight or worker selection, the sync aborts with an error.
- If `UIDVALIDITY` changes between preflight and fetch, the sync aborts for that mailbox; rerun to proceed under the new generation.
- Mailboxes with zero missing UIDs (nothing to fetch) are skipped to save time and connections.
 - Read‑only IMAP: mailboxes are opened with `EXAMINE` and bodies are fetched with `BODY.PEEK[]`, so the sync does not mark messages as read or change flags.

### Performance considerations

- Batched fetch: messages are fetched in batches (default size: 100 UIDs) using `UID FETCH` with `BODY.PEEK[]`, `FLAGS`, Gmail extensions, and `UID`. This significantly reduces round‑trips vs one‑by‑one fetch.
- Connection safety: using `EXAMINE` keeps sessions read‑only; `BODY.PEEK[]` avoids setting `\\Seen` on unread messages.

 - Server‑diff requires the server to return the full UID list for each mailbox; this is efficient server‑side but can be sizable over the wire for very large mailboxes (tens/hundreds of thousands of messages). Preflight is parallelized with `MAILBOX_THREADS` to mitigate wall‑clock time.

## Linting

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
  You can later derive a date from other headers (e.g., `Received`) or IMAP `INTERNALDATE` downstream if needed.

## Contributing

Bug reports and pull requests are welcome on GitHub at <https://github.com/parasquid/nittymail/issues>

## Gmail IMAP Extensions

This project uses Gmail-specific IMAP attributes for richer metadata. See docs/gmail-imap-extensions.md for details on X-GM-LABELS, X-GM-MSGID, and X-GM-THRID.

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
