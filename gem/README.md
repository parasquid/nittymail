# NittyMail Gem

A Ruby gem providing core IMAP operations and email processing functionality for the NittyMail CLI application. This gem handles Gmail/IMAP connections, email parsing, and metadata extraction.

## Features

- **IMAP Operations**: Connect to Gmail/IMAP servers and fetch emails
- **Email Parsing**: Extract metadata from raw RFC822 email messages
- **Settings Management**: Configuration handling for IMAP connections
- **Error Handling**: Comprehensive exception handling for IMAP operations
- **Docker Workflow**: Complete Docker-based development environment

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'nitty_mail'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install nitty_mail
```

## Docker Development Workflow

This gem uses Docker Compose for development, similar to the CLI. No local Ruby installation required.

### Prerequisites

- Docker and Docker Compose installed

### Setup

1. **Configure Environment** (optional):
   ```bash
   cp .env.sample .env
   # Edit .env if you need IMAP credentials for testing
   ```

2. **Dependencies install automatically** on first run via the entrypoint script.

### Usage

#### Interactive Shell
```bash
docker compose run --rm gem
```

#### Run Tests
```bash
# Full test suite
docker compose run --rm gem bundle exec rspec -fd -b

# Single test file
docker compose run --rm gem bundle exec rspec -fd -b spec/NittyMail/utils_spec.rb
```

#### Run Rake Tasks
```bash
# Run all rake tasks (specs + linting)
docker compose run --rm gem rake

# Build gem
docker compose run --rm gem rake build

# Install locally
docker compose run --rm gem rake install
```

#### Development Console
```bash
docker compose run --rm gem bin/console
```

#### Linting
```bash
# Auto-fix
docker compose run --rm gem bundle exec standardrb --fix
docker compose run --rm gem bundle exec rubocop -A

# Check only
docker compose run --rm gem bundle exec standardrb
docker compose run --rm gem bundle exec rubocop
```

## Architecture

### Core Modules

- **`NittyMail::Mailbox`**: IMAP client operations and email fetching
- **`NittyMail::Enricher`**: Email parsing and metadata extraction
- **`NittyMail::Settings`**: Configuration management
- **`NittyMail::Utils`**: Shared utility functions
- **`NittyMail::Errors`**: Custom exception classes

### Key Classes

```ruby
# IMAP operations
mailbox = NittyMail::Mailbox.new(settings: settings)
emails = mailbox.fetch(uids: [1, 2, 3])

# Email parsing
enriched = NittyMail::Enricher.enrich(raw_email_content)

# Configuration
settings = NittyMail::Settings.new(
  imap_address: "user@gmail.com",
  imap_password: "app-password"
)
```

## Development

### Testing

The gem uses RSpec with `rspec-given` for BDD-style tests:

```ruby
describe NittyMail::Utils do
  Given(:input) { "test@example.com" }

  When(:result) { described_class.sanitize_collection_name(input) }

  Then { expect(result).to eq("test-example-com") }
end
```

### Code Style

- **StandardRB**: Primary linting tool
- **RuboCop**: Additional style enforcement
- **Hash Shorthand**: Use `{key:}` when key matches variable
- **Method Names**: `snake_case` for methods, `CamelCase` for classes

### Building & Releasing

```bash
# Build the gem
rake build

# Install locally for testing
rake install

# Release to RubyGems (requires credentials)
rake release
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes with tests
4. Run the full test suite: `docker compose run --rm gem rake`
5. Submit a pull request

## License

The gem is available as open source under the terms of the [LICENSE](LICENSE).

## Agent Guide

See `AGENTS.md` for AI agent development guidelines and conventions.
