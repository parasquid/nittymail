# NittyMail Core

This folder contains some common functionality, among which is a simple syncing script that will download all messages in a Gmail account to an sqlite3 database.

## Usage

### Prerequisites

Before running NittyMail, you need to prepare your Gmail account:

#### 1. Enable IMAP Access
1. Open Gmail in your web browser
2. Click the gear icon (⚙️) in the top right corner
3. Select **"See all settings"**
4. Go to the **"Forwarding and POP/IMAP"** tab
5. In the **"IMAP access"** section, select **"Enable IMAP"**
6. Click **"Save Changes"** at the bottom

*Reference: [Gmail IMAP documentation](https://support.google.com/mail/answer/7126229)*

#### 2. Set Up App Password (Required for 2FA accounts)
If your Gmail account has 2-Factor Authentication enabled, you'll need an App Password:

1. Go to your [Google Account settings](https://myaccount.google.com/)
2. Select **"Security"** from the left sidebar
3. Under **"How you sign in to Google"**, click **"2-Step Verification"**
4. Scroll down and click **"App passwords"**
5. Select **"Mail"** from the dropdown
6. Choose **"Other (Custom name)"** and enter "NittyMail"
7. Click **"Generate"**
8. **Copy the 16-character password** - you'll use this instead of your regular Gmail password

*Reference: [Google App Passwords documentation](https://support.google.com/accounts/answer/185833)*

#### 3. Configure NittyMail
1. Copy the sample configuration file:
   ```bash
   cp core/config/.env.sample core/config/.env
   ```

2. Edit `core/config/.env` with your details:
   ```bash
   ADDRESS="your-email@gmail.com"
   PASSWORD="your-app-password-or-regular-password"
   DATABASE="data/your-email.sqlite3"
   ```

### Running NittyMail

With Docker and Docker Compose installed:

``` bash
# Install dependencies
docker compose run --rm ruby bundle

# Run the sync (you'll be prompted to confirm)
docker compose run --rm ruby ./sync.rb

# Optional: Add this alias to your terminal configuration for convenience
alias dcr='docker compose run --rm'
dcr ruby ./sync.rb
```

### Advanced Options

**Automated/Non-interactive runs:**
```bash
SYNC_AUTO_CONFIRM=yes docker compose run --rm ruby ./sync.rb
```

**Multi-threaded sync for large mailboxes:**
```bash
THREADS=4 docker compose run --rm ruby ./sync.rb
```
*Keep thread counts reasonable (2-8) to avoid Gmail IMAP throttling.*

**Verify sync results:**
```bash
sqlite3 core/data/your-email.sqlite3 'SELECT COUNT(*) FROM email;'
```

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
