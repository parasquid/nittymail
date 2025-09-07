# Repository Guidelines

## Project Structure & Module Organization
- `lib/`: Gem source code (e.g., `NittyMail`, `Mailbox`, `Settings`).
- `spec/`: RSpec tests; `spec_helper.rb` configures defaults.
- `bin/`: Developer helpers (`console`, `setup`).
- `NittyMail.gemspec`, `Gemfile`, `Rakefile`: Gem metadata and rake tasks.

## Build, Test, and Development Commands

### Dependencies & Setup
- Install deps: `bundle install`
- Open REPL with gem loaded: `bin/console`

### Running Tests
```bash
# Full test suite (from gem/ directory)
bundle exec rspec -fd -b

# Single test file
bundle exec rspec -fd -b spec/NittyMail/utils_spec.rb

# Specific test pattern
bundle exec rspec -fd -b --pattern "**/*mailbox*"

# From project root (using Docker)
docker compose run --rm ruby bundle exec rspec -fd -b gem/spec/
```

### Linting & Quality
- Lint + test (default): `bundle exec rake` (runs `spec` and StandardRB)
- StandardRB only: `bundle exec standardrb`
- RuboCop only: `bundle exec rubocop`

### Troubleshooting
- **Missing dependencies**: Run `bundle install` first
- **Test failures**: Check Ruby version compatibility (requires Ruby 3.4+)
- **Load path issues**: Ensure you're in the correct directory when running commands

## Coding Style & Naming Conventions
- Style: StandardRB is canonical; RuboCop config aligns with it.
- Indentation: 2 spaces; no tabs.
- Naming: Classes `CamelCase`; methods/variables `snake_case`; constants `UPPER_SNAKE`.
- Hash shorthand when key equals variable (e.g., `{foo:}`).
- Exceptions: rescue specific errors; no silent rescues; avoid modifier `rescue`.

## Testing Guidelines
- Framework: RSpec 3.x with `rspec-given` macros.
- Style: Prefer Given/When/Then/And; keep scenarios small and focused.
- Location: mirror `lib/` paths under `spec/`; filenames end with `_spec.rb`.
- Example:
  ```ruby
  require "spec_helper"
  RSpec.describe NittyMail do
    Given(:version) { NittyMail::VERSION }
    Then { expect(version).to be_a(String) }
  end
  ```

## Commit & Pull Request Guidelines
- Conventional Commits: `type(scope): subject`.
- Use heredoc commit messages to satisfy hooks:
  ```bash
  git commit -F - << 'EOF'
  feat(core): add mailbox preflight helper

  Why:
  - Short motivation.

  What:
  - Brief summary of changes.
  EOF
  ```
- PRs: clear description, linked issues, local test instructions, and screenshots for user-facing changes.

## Security & Configuration Tips
- Do not commit secrets or tokens; prefer environment variables for local dev.
- Document any new configuration keys in `README.md` and provide sane defaults.

## Agent-Specific Instructions
- Keep changes minimal and focused; avoid unrelated refactors.
- Fail fast on initialization errors with actionable messages; do not swallow exceptions.
