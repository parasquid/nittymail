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

## Commit & Pull Request Guidelines
- **MANDATORY**: Run linting before every commit. Both StandardRB and RuboCop must pass with zero offenses.
  - `docker compose run --rm ruby bundle exec standardrb .`
  - `docker compose run --rm ruby bundle exec rubocop --config ../.rubocop.yml .`
- **Commit Format**: Use Conventional Commits format: `<type>(<scope>): <description>`
  - Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`
  - Examples: `feat(sync): add multi-threading support`, `fix(imap): handle nil message ids`, `docs: update threading usage`
- Group related changes; avoid unrelated refactors.
- PRs: include purpose, approach, test plan (commands/output), and any related issue (e.g., "Fixes #123").
- AI agents: Always run linting commands before staging any commit. Do not proceed with commits if linting fails. Use conventional commit format.

## Configuration Management
- **Environment Variables**: All configuration via environment variables or `.env` file.
- **Required Variables**:
  - `ADDRESS`: Gmail address to sync
  - `PASSWORD`: Gmail password (use App Password if 2FA enabled)
  - `DATABASE`: SQLite database path (e.g., `data/<email>.sqlite3`)
- **Optional Variables**:
  - `SYNC_AUTO_CONFIRM=yes`: Skip confirmation prompt for automated runs
  - `THREADS=<n>`: Number of worker threads (default: 1, keep reasonable to avoid throttling)
- **Adding New Config**: When adding new environment variables, update both `.env.sample` and documentation.
- **Validation**: Add validation for new config options; fail fast with clear error messages.

## Security & Configuration Tips
- Do not commit secrets. Use `config/.env` (copy from `.env.sample`).
- IMAP must be enabled on the Gmail account.
- Use Gmail App Passwords when 2FA is enabled.
- Keep thread counts reasonable to avoid Gmail IMAP throttling.

## Architecture Overview
- IMAP fetch via `mail` gem, with Gmail extensions patched at runtime.
- Persistence via `sequel` to SQLite; one table `email` indexed by mailbox, UID, and validity.
