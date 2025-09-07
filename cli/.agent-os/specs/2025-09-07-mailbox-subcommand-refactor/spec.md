# Spec Requirements Document

> Spec: Mailbox Subcommand Refactor
> Created: 2025-09-07

## Overview

Refactor the mailbox command structure to extract each mailbox subcommand (list, download, archive) into separate classes to improve code organization and maintainability. This will reduce the size of the monolithic Mailbox class and make each mailbox subcommand easier to test and maintain independently.

## User Stories

### Developer Code Maintenance

As a developer, I want each mailbox subcommand to live in its own class, so that the code is more organized and easier to maintain.

The current `cli/commands/mailbox.rb` file is 700+ lines and contains three distinct subcommands: `list`, `download`, and `archive`. Each subcommand has its own complex logic, options, and error handling. By extracting these into separate classes, developers can work on individual features without navigating through unrelated code, making the codebase more modular and testable.

## Spec Scope

1. **Mailbox::List Class** - Extract the `list` subcommand into `cli/commands/mailbox/list.rb`
2. **Mailbox::Download Class** - Extract the `download` subcommand into `cli/commands/mailbox/download.rb`  
3. **Mailbox::Archive Class** - Extract the `archive` subcommand into `cli/commands/mailbox/archive.rb`
4. **Main Mailbox Class Update** - Refactor `cli/commands/mailbox.rb` to delegate to the new subcommand classes
5. **Preserve Existing Functionality** - Ensure all existing CLI options, error handling, and behavior remain identical

## Out of Scope

- Changing any CLI option names, descriptions, or behaviors
- Modifying the underlying IMAP functionality or job processing logic
- Adding new features or mailbox subcommands during this refactor
- Changing the public Thor interface or command structure
- Extracting other CLI subcommands (like `db` commands) - focus only on mailbox subcommands

## Expected Deliverable

1. Each subcommand runs identically to before the refactor with all existing options and error handling preserved
2. The main `cli/commands/mailbox.rb` file is significantly reduced in size and delegates to subcommand classes
3. All existing tests continue to pass without modification