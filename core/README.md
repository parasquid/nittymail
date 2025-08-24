# NittyMail Core

This folder contains some common functionality, among which is a simple syncing script that will download all messages in a Gmail account to an sqlite3 database.

## Usage

You will need to enable IMAP for the Gmail account that will be synced. Support documentation can be found at <https://support.google.com/mail/answer/7126229>

If the account has 2FA enabled, an app password will need to be generated and used instead of the account password. More documentation found at <https://support.google.com/accounts/answer/185833>

Configuration is done through the `.env` file; there is a sample `.env.sample` that can be copied and modified as necessary.

A docker-compose.yml has been provided for convenience. With `docker ` and `docker-compose` installed:

``` bash
# you can also add this alias to your terminal's configuration
alias dcr='docker compose -f core/docker-compose.yml run --rm'

dcr ruby bundle
dcr ruby ./sync.rb
```

For non-interactive or automated runs, set `SYNC_AUTO_CONFIRM=yes` to skip the confirmation prompt.

To speed up large mailbox syncs, you can use threads:

```bash
THREADS=4 dcr ruby ./sync.rb
```
Keep values reasonable to avoid IMAP throttling.

## Contributing

Bug reports and pull requests are welcome on GitHub at <https://github.com/parasquid/nittymail/issues>

## Gmail IMAP Extensions

This project uses Gmail-specific IMAP attributes for richer metadata. See docs/gmail-imap-extensions.md for details on X-GM-LABELS, X-GM-MSGID, and X-GM-THRID.

## License

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
