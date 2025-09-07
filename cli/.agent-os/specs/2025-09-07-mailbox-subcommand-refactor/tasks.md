# Spec Tasks

## Tasks

- [x] 1. Create Mailbox::List subcommand class
  - [x] 1.1 Write tests for Mailbox::List class functionality
  - [x] 1.2 Create `cli/commands/mailbox/list.rb` with List class inheriting from Thor
  - [x] 1.3 Extract `list` method and all related logic from main Mailbox class
  - [x] 1.4 Move all `list` method_option definitions to new List class
  - [x] 1.5 Ensure proper require statements and error handling are preserved
  - [x] 1.6 Verify all tests pass

- [x] 2. Create Mailbox::Download subcommand class
  - [x] 2.1 Write tests for Mailbox::Download class functionality
  - [x] 2.2 Create `cli/commands/mailbox/download.rb` with Download class inheriting from Thor
  - [x] 2.3 Extract `download` method and all related logic from main Mailbox class
  - [x] 2.4 Move all `download` method_option definitions to new Download class
  - [x] 2.5 Preserve job integration, Redis handling, and progress bar functionality
  - [x] 2.6 Maintain strict mode, recreate, and purge_uidvalidity options behavior
  - [x] 2.7 Verify all tests pass

- [x] 3. Create Mailbox::Archive subcommand class
  - [x] 3.1 Write tests for Mailbox::Archive class functionality
  - [x] 3.2 Create `cli/commands/mailbox/archive.rb` with Archive class inheriting from Thor
  - [x] 3.3 Extract `archive` method and all related logic from main Mailbox class
  - [x] 3.4 Move all `archive` method_option definitions to new Archive class
  - [x] 3.5 Preserve job integration and file handling functionality
  - [x] 3.6 Verify all tests pass

- [x] 4. Refactor main Mailbox class to use subcommands
  - [x] 4.1 Write tests for updated main Mailbox class delegation
  - [x] 4.2 Update `cli/commands/mailbox.rb` to use Thor subcommand feature
  - [x] 4.3 Add proper require statements for new subcommand classes
  - [x] 4.4 Remove extracted methods from main class while preserving any shared utilities
  - [x] 4.5 Verify CLI interface remains identical for all commands
  - [x] 4.6 Verify all existing tests continue to pass

- [x] 5. Integration testing and cleanup
  - [x] 5.1 Run full test suite to ensure no regressions
  - [x] 5.2 Test CLI commands manually to verify identical behavior
  - [x] 5.3 Update any documentation if file paths changed
  - [x] 5.4 Clean up any unused imports or dead code
  - [x] 5.5 Verify all tests pass and code follows project style guidelines

- [x] 6. Fix failing test specs after refactoring
  - [x] 6.1 Update test files to use new subcommand classes (MailboxArchive, MailboxDownload, MailboxList)
  - [x] 6.2 Fix mock expectations for updated class structure
  - [x] 6.3 Verify all 26 CLI tests pass with 0 failures