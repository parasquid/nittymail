# NittyMail CLI (Docker Compose)

This folder provides a Docker-only workflow for the NittyMail CLI. You do not need Ruby installed locally — all commands run via Docker Compose.

## Prerequisites

- Docker and Docker Compose installed

## Setup

1. Copy the sample env and set your credentials:
   ```bash
   cp .env.sample .env
   # Edit .env and set NITTYMAIL_IMAP_ADDRESS and NITTYMAIL_IMAP_PASSWORD
   ```

2. Dependencies install automatically on first run (bundle install is run by the entrypoint). You can still run it manually if desired:
   ```bash
   docker compose run --rm cli bundle install
   ```

## Usage

- List mailboxes for your account (shortcut; no `./cli.rb` needed). Flags are optional if env vars are set:
  ```bash
  # using env vars only
  docker compose run --rm cli mailbox list

  # or pass credentials explicitly
  docker compose run --rm cli mailbox list \
    -a "$NITTYMAIL_IMAP_ADDRESS" -p "$NITTYMAIL_IMAP_PASSWORD"
  ```

- Open an interactive shell in the CLI container:
  ```bash
  docker compose run --rm cli bash
  ```

## Notes

- The Compose service mounts the repository root so the local gem at `../gem` (declared in `Gemfile`) is available in-container.
- No host Ruby required; all commands are executed via the `cli` service.
