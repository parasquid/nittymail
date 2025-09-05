# Database Schema

This is the database schema implementation for the spec detailed in @.agent-os/specs/2025-09-05-sidekiq-mailbox-download/spec.md

No schema changes are required. The job-mode writer uses the existing `emails` table and indexes. All idempotency is enforced by the current composite unique index (`address`, `mailbox`, `uidvalidity`, `uid`).

