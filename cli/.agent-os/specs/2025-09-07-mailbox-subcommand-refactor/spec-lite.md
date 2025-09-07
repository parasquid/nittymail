# Spec Summary (Lite)

Refactor the mailbox command structure to extract each mailbox subcommand (list, download, archive) into separate classes to improve code organization and maintainability. This will reduce the size of the monolithic Mailbox class and make each mailbox subcommand easier to test and maintain independently.