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
- Install deps: `cd core && docker compose run --rm ruby bundle`
- Run sync: `cd core && docker compose run --rm ruby ./sync.rb`
- Lint (StandardRB): `cd core && docker compose run --rm ruby bundle exec standardrb`
- Lint (RuboCop): `cd core && docker compose run --rm ruby bundle exec rubocop`
- Verify DB rows: `sqlite3 core/data/<email>.sqlite3 'SELECT COUNT(*) FROM email;'`
Note: Configure `core/config/.env` first (see below).

## Coding Style & Naming Conventions
- Language: Ruby 3.4.x (Docker image).
- Indentation: 2 spaces; UTF‑8 strings.
- Files: snake_case for `.rb`; constants in `SCREAMING_SNAKE_CASE`.
- Linters: StandardRB (`bundle exec standardrb`) and RuboCop (`bundle exec rubocop`) configured to follow Standard.

## Error Handling & Concurrency
- Do not swallow exceptions. Avoid `rescue => e` without re-raise; rescue specific errors only.
- No rescue-modifier one-liners (e.g., `foo rescue nil`). Prefer explicit begin/rescue.
- For threads, surface failures: we use `Thread.abort_on_exception = true` when `THREADS>1`.
- Keep DB writes consistent; a single writer thread inserts records. Non-unique inserts are skipped explicitly; other errors fail fast.

## Testing Guidelines
- Current: manual verification via the generated SQLite DB.
- Naming: test helpers under `core/` as needed; prefer isolated functions.
- Suggested (future): RSpec with unit tests around IMAP parsing and DB writes.
- Quick check: run sync against a test account; query counts and spot‑check fields.

## Commit & Pull Request Guidelines
- **MANDATORY**: Run linting before every commit. Both StandardRB and RuboCop must pass with zero offenses.
  - `cd core && docker compose run --rm ruby bundle exec standardrb`
  - `cd core && docker compose run --rm ruby bundle exec rubocop`
- **Commit Format**: Use Conventional Commits format: `<type>(<scope>): <description>`
  - Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`
  - Examples: `feat(sync): add multi-threading support`, `fix(imap): handle nil message ids`, `docs: update threading usage`
- Group related changes; avoid unrelated refactors.
- PRs: include purpose, approach, test plan (commands/output), and any related issue (e.g., "Fixes #123").
- AI agents: Always run linting commands before staging any commit. Do not proceed with commits if linting fails. Use conventional commit format.

## Security & Configuration Tips
- Do not commit secrets. Use `config/.env` (copy from `.env.sample`).
- Required keys: `ADDRESS`, `PASSWORD` (use Gmail App Password if 2FA), `DATABASE` (e.g., `data/<email>.sqlite3`).
- IMAP must be enabled on the account.
- Non-interactive runs: set `SYNC_AUTO_CONFIRM=yes` to skip the confirmation prompt.
 - Performance: set `THREADS=<n>` for multi-threaded sync (default 1). Keep reasonable to avoid Gmail throttling.

## Architecture Overview
- IMAP fetch via `mail` gem, with Gmail extensions patched at runtime.
- Persistence via `sequel` to SQLite; one table `email` indexed by mailbox, UID, and validity.
