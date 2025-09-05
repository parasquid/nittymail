# Tech Stack

## Context

Global defaults aligned with this repository's `cli/` implementation. Project‑specific deviations may be defined in `.agent-os/product/tech-stack.md`.

- Application Type: Ruby CLI (no Rails)
- Language/Version: Ruby 3.4
- Runtime: Docker Compose (services: cli, redis, worker_fetch, worker_write, monitor)
- Package Manager: Bundler

## Data & Persistence

- Database: SQLite 3 (file‑backed)
- ORM: Active Record (AR 8.x)
- Pragmas: WAL journaling, synchronous=NORMAL, temp_store=MEMORY
- Migrations: AR migrations under `cli/db/migrate`

## Background Jobs

- Job Framework: Active Job
- Queue Adapter: Sidekiq
- Broker: Redis 7
- Queues: `fetch` (parallel), `write` (single‑concurrency by default)
- Monitoring: Sidekiq Web via Rack (`config.ru`) served by WEBrick

## Email/IMAP

- IMAP/Gmail: `nitty_mail` gem (local path `../gem`) for preflight/fetch
- Message Parsing: `mail`
- Markdown Conversion: `reverse_markdown`

## CLI & UX

- CLI Framework: Thor
- Progress: `ruby-progressbar`
- Env Management: `dotenv`

## Testing & Quality

- Tests: RSpec with `rspec-given`
- Lint/Format: `standard` and `rubocop`

## Operations

- Local Orchestration: Docker Compose
- Scaling Pattern: scale processes via Compose (`worker_fetch` replicas) or adjust concurrency in Sidekiq config
- Logs: ActiveJob enqueue argument logs suppressed to avoid leaking secrets

## Not Used

- No Rails, React, Node/Vite, Tailwind, or cloud PaaS defaults in this CLI scope
