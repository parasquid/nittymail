# AI Agent MUST: Commit Messages

Always create multi-line commit messages without literal "\n". Use one of these exact patterns:

- Heredoc (preferred):
  - `git commit -F - << 'EOF'
    type(scope): subject

    Why:
    - short bullets

    What:
    - short bullets
    EOF`
- Multiple messages (each `-m` is a paragraph):
  - `git commit -m "type(scope): subject" -m "Why:" -m "- short bullet" -m "" -m "What:" -m "- short bullet"`

Rules:
- Never include the characters "\n" inside any `-m` string.
- Prefer the heredoc when you need multi-line bullets or longer bodies.

# AI Agent MUST: Tests Pass Before Commit

Run the test suite in Docker and ensure it exits 0 before committing any code that adds or changes behavior.

- Install gems: `docker compose run --rm ruby bundle`
- Run tests: `docker compose run --rm ruby bundle exec rspec`
- Only commit after tests are green. If tests fail, fix code and/or update tests, then re-run.

# AI Agent MUST: Auto-fix Lint First

Always run StandardRB auto-fix before making manual style changes.

- Install gems: `docker compose run --rm ruby bundle`
- Auto-fix: `docker compose run --rm ruby bundle exec standardrb --fix .`
- Verify: `docker compose run --rm ruby bundle exec standardrb .`
- Verify: `docker compose run --rm ruby bundle exec rubocop --config ../.rubocop.yml .`
- Only if issues remain should you apply targeted manual fixes, then re-run both linters.
- Do not commit until both linters pass with zero offenses.

# Repository Guidelines

## Project Structure & Module Organization
- Root: licensing and this guide.
- `core/`: Ruby code and tooling.
  - `sync.rb`: Gmail→SQLite sync script (Sequel + Mail).
  - `Gemfile`, `Gemfile.lock`: dependencies.
  - `docker-compose.yml`: containerized dev runtime.
  - `config/.env.sample`: copy to `config/.env` for local secrets.
  - `data/`: SQLite databases (one per address).

## Build, Test, and Development Commands
- Policy: Use Docker only. Do not use host Ruby/Bundler.
- Install deps: `docker compose run --rm ruby bundle`
- Run sync: `docker compose run --rm ruby ../cli.rb sync`
- Lint (StandardRB): `docker compose run --rm ruby bundle exec standardrb .`
- Lint (RuboCop): `docker compose run --rm ruby bundle exec rubocop --config ../.rubocop.yml .`
- Verify DB rows: `sqlite3 core/data/<email>.sqlite3 'SELECT COUNT(*) FROM email;'`
Note: Configure `core/config/.env` first (see below).

### Linting Details (Docker)
- Working directory in the container is `/app/core`.
- RuboCop must be pointed at the root config: `--config ../.rubocop.yml`.
- Install gems first with `docker compose run --rm ruby bundle`.
- Auto-fix safe issues: `docker compose run --rm ruby bundle exec standardrb --fix .`.
- Both linters must pass (exit code 0) before commits/PRs.
 - StandardRB output tip: When StandardRB exits non‑zero but shows no output, re-run with a verbose formatter or capture stderr to reveal offenses:
   - `docker compose run --rm ruby bundle exec standardrb --format progress .`
   - or `docker compose run --rm ruby bundle exec standardrb . 2>&1 | cat`
   Use `--fix` where safe, then re-run.

## Coding Style & Naming Conventions
- Language: Ruby 3.4.x (Docker image).
- Indentation: 2 spaces; UTF‑8 strings.
- Files: snake_case for `.rb`; constants in `SCREAMING_SNAKE_CASE`.
- Linters: StandardRB (`bundle exec standardrb`) and RuboCop (`bundle exec rubocop`) configured to follow Standard.
- Sequel-specific linting: RuboCop-Sequel extension for database-related code quality and security.

## Error Handling & Concurrency
- Do not swallow exceptions. Avoid `rescue => e` without re-raise; rescue specific errors only.
- No rescue-modifier one-liners (e.g., `foo rescue nil`). Prefer explicit begin/rescue.
- For threads, surface failures: we use `Thread.abort_on_exception = true` when `THREADS>1`.
- Keep DB writes consistent; a single writer thread inserts records. Non-unique inserts are skipped explicitly; other errors fail fast.

## Documentation Guidelines (Living Documentation)
- **MANDATORY**: Update documentation whenever making significant changes to functionality.
- **New Features**: Document new environment variables, command-line flags, or configuration options in both `AGENTS.md` and `core/README.md`.
- **Breaking Changes**: Clearly mark and explain any breaking changes in usage or configuration.
- **Examples**: Always provide concrete usage examples for new features (e.g., `THREADS=4 dcr ruby ./sync.rb`).
- **Architecture Changes**: Update the "Architecture Overview" section when core mechanisms change.
- **Keep Docs Close**: Documentation should live near the code it describes; update both simultaneously.
- **User-Facing vs Internal**: Distinguish between user documentation (`core/README.md`) and developer/AI guidelines (`AGENTS.md`).
- **Version Compatibility**: Note any version requirements or compatibility changes.
- **AI Agents**: When implementing features, always check if existing documentation needs updates. Documentation debt creates confusion.

## Testing Guidelines
- Current: manual verification via the generated SQLite DB.
- Naming: test helpers under `core/` as needed; prefer isolated functions.
- Suggested (future): RSpec with unit tests around IMAP parsing and DB writes.
- Quick check: run sync against a test account; query counts and spot‑check fields.

### Edge Cases
- Messages with missing/invalid `Date:` header: the Mail gem may raise `Mail::Field::NilParseError` when parsing. The sync logic intentionally sets `date = NULL` and proceeds to avoid aborting the run. Downstream consumers should tolerate `NULL` dates or derive a timestamp from other sources if required (e.g., `INTERNALDATE` or `Received` headers).

## Commit & Pull Request Guidelines
- **MANDATORY**: Run linting before every commit. Both StandardRB and RuboCop must pass with zero offenses.
  - `docker compose run --rm ruby bundle exec standardrb .`
  - `docker compose run --rm ruby bundle exec rubocop --config ../.rubocop.yml .`
- **Commit Format**: Use Conventional Commits format: `<type>(<scope>): <description>`
  - Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`
  - Examples: `feat(sync): add multi-threading support`, `fix(imap): handle nil message ids`, `docs: update threading usage`
- **Include the Why for significant changes**: For user-facing or behavior-changing commits, add a short rationale section in the body explaining why the change is needed. Prefer a structured body with:
  - `Why:` one or two bullets on motivation
  - `What:` concise list of changes
  - `Notes:` optional caveats or follow-ups
- Group related changes; avoid unrelated refactors.
- PRs: include purpose, approach, test plan (commands/output), and any related issue (e.g., "Fixes #123").
- AI agents: Always run linting commands before staging any commit. Do not proceed with commits if linting fails. Use conventional commit format.

### Multi-line Commit Messages (Newlines)
- Prefer multiple `-m` flags for portability: `git commit -m "feat: subject" -m "Why: ..." -m "What: ..."`.
- For longer bodies, use a file: write to `COMMIT_MSG.txt` and run `git commit -F COMMIT_MSG.txt`.
- Or use a heredoc to pass a body with proper newlines:
  - `git commit --amend -F - << 'EOF'
    feat(scope): concise subject

    Why:
    - one or two bullets

    What:
    - short list of changes

    Notes:
    - optional caveats
    EOF`
- Shell quoting tips: use single quotes around `EOF` to avoid interpolation; ensure `EOF` is on its own line with no trailing spaces; avoid unescaped backslashes in the body.

#### Do not put literal `\n` in messages
- Never type `\n` inside `-m` strings expecting it to become a newline — it will be stored literally.
- If you see backslashes in your message content, stop and use `-F` with a file or the heredoc approach above.

#### Verify before pushing
- Check for literal `\n` sequences in your recent commit bodies:
  - `git log -n 5 --pretty=%B | grep -F '\\n' && echo 'Found literal \\n in commit messages' && exit 1 || true`
- Inspect the last commit body exactly as Git sees it:
  - `git log -1 --pretty=%B`
  - `git log -1 --pretty=%B | sed -n 'l'` (shows control chars; `\n` should not appear literally)

#### If you slipped, fix it immediately
- Amend the last commit with a proper multi-line body:
  - `git commit --amend -F - << 'EOF'
    type(scope): subject

    Why:
    - rationale here

    What:
    - changes here
    EOF`
- For multiple bad commits, rebase or re-create them: save patches, reset, re-apply, and recommit with corrected messages; then `git push --force-with-lease`.

## Configuration Management
- **Environment Variables**: All configuration via environment variables or `.env` file.
- **Required Variables**:
  - `ADDRESS`: Gmail address to sync
  - `PASSWORD`: Gmail password (use App Password if 2FA enabled)
  - `DATABASE`: SQLite database path (e.g., `data/<email>.sqlite3`)
- **Optional Variables**:
  - `SYNC_AUTO_CONFIRM=yes`: Skip confirmation prompt for automated runs
  - `THREADS=<n>`: Number of worker threads (default: 1, keep reasonable to avoid throttling)
  - `MAILBOX_THREADS=<n>`: Number of threads used to preflight mailboxes (discover UID lists) in parallel; defaults to 1. Keep combined IMAP connections under Gmail limits.
  - `PURGE_OLD_VALIDITY=yes`: Automatically delete rows from older UIDVALIDITY generations after a successful mailbox sync when a change is detected.
  - `FETCH_BATCH_SIZE=<n>`: Number of UIDs per `UID FETCH` request (default: 100). CLI flag `--fetch-batch-size` overrides.
  - `MAILBOX_IGNORE="Spam,Trash"`: Comma-separated mailbox names/patterns to skip (supports `*` and `?`). Default recommendation is to ignore Spam and Trash to reduce unnecessary data. CLI flag `--ignore-mailboxes` overrides.
  - CLI flags override env when provided: `--threads N` and `--mailbox-threads N`. If neither flag nor env var is provided, both default to 1.
- **Adding New Config**: When adding new environment variables, update both `.env.sample` and documentation.
- **Validation**: Add validation for new config options; fail fast with clear error messages.

## Security & Configuration Tips
- Do not commit secrets. Use `config/.env` (copy from `.env.sample`).
- IMAP must be enabled on the Gmail account.
- Use Gmail App Passwords when 2FA is enabled.
- Keep thread counts reasonable to avoid Gmail IMAP throttling.

## Architecture Overview
- IMAP fetch via `mail` gem, with Gmail extensions patched at runtime.
- Preflight uses a server‑diff per mailbox (`UID 1:*` vs local DB for current `UIDVALIDITY`) to compute missing UIDs.
- Workers re‑check `UIDVALIDITY` after `SELECT`; a mismatch aborts with an error.
- Persistence via `sequel` to SQLite; one table `email` indexed by mailbox, UID, and validity.
- Optimization: Mailboxes with zero missing UIDs are skipped during the fetch phase.
 - Read‑only and batched fetches: workers use `EXAMINE` and `UID FETCH` with `BODY.PEEK[]` in batches (default 100 UIDs) to avoid changing flags and reduce round‑trips.
