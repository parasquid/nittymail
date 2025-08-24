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
- Install deps: `cd core && docker compose run --rm -u 1000:1000 ruby bundle`
- Run sync: `cd core && docker compose run --rm -u 1000:1000 ruby ./sync.rb`
- Lint (StandardRB): `cd core && docker compose run --rm -u 1000:1000 ruby bundle exec standardrb`
- Lint (RuboCop): `cd core && docker compose run --rm -u 1000:1000 ruby bundle exec rubocop`
- Verify DB rows: `sqlite3 core/data/<email>.sqlite3 'SELECT COUNT(*) FROM email;'`
Note: Configure `core/config/.env` first (see below).

## Coding Style & Naming Conventions
- Language: Ruby 3.1.x (see Docker image).
- Indentation: 2 spaces; UTF‑8 strings.
- Files: snake_case for `.rb`; constants in `SCREAMING_SNAKE_CASE`.
- Linters: StandardRB (`bundle exec standardrb`) and RuboCop (`bundle exec rubocop`) configured to follow Standard.

## Testing Guidelines
- Current: manual verification via the generated SQLite DB.
- Naming: test helpers under `core/` as needed; prefer isolated functions.
- Suggested (future): RSpec with unit tests around IMAP parsing and DB writes.
- Quick check: run sync against a test account; query counts and spot‑check fields.

## Commit & Pull Request Guidelines
- Commits: short, imperative subject lines (e.g., "handle nil message ids").
- Group related changes; avoid unrelated refactors.
- PRs: include purpose, approach, test plan (commands/output), and any related issue (e.g., "Fixes #123").

## Security & Configuration Tips
- Do not commit secrets. Use `config/.env` (copy from `.env.sample`).
- Required keys: `ADDRESS`, `PASSWORD` (use Gmail App Password if 2FA), `DATABASE` (e.g., `data/<email>.sqlite3`).
- IMAP must be enabled on the account.

## Architecture Overview
- IMAP fetch via `mail` gem, with Gmail extensions patched at runtime.
- Persistence via `sequel` to SQLite; one table `email` indexed by mailbox, UID, and validity.
