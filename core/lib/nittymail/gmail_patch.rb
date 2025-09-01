# frozen_string_literal: true

# Copyright 2025 parasquid

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

module NittyMail
  module GmailPatch
    module_function

    def apply(gmail_imap)
      class << gmail_imap.instance_variable_get(:@parser)
        def msg_att(n)
          match(T_LPAR)
          attr = {}
          loop do
            token = lookahead
            case token.symbol
            when T_RPAR
              shift_token
              break
            when T_SPACE
              shift_token
              next
            end
            case token.value
            when /\A(?:ENVELOPE)\z/ni
              name, val = envelope_data
            when /\A(?:FLAGS)\z/ni
              name, val = flags_data
            when /\A(?:INTERNALDATE)\z/ni
              name, val = internaldate_data
            when /\A(?:RFC822(?:\.HEADER|\.TEXT)?)\z/ni
              name, val = rfc822_text
            when /\A(?:RFC822\.SIZE)\z/ni
              name, val = rfc822_size
            when /\A(?:BODY(?:STRUCTURE)?)\z/ni
              name, val = body_data
            when /\A(?:UID)\z/ni
              name, val = uid_data
            when /\A(?:MODSEQ)\z/ni
              name, val = modseq_data

            # Gmail extended attributes
            when /\A(?:X-GM-LABELS)\z/ni
              name, val = flags_data
            when /\A(?:X-GM-MSGID)\z/ni
              name, val = uid_data
            when /\A(?:X-GM-THRID)\z/ni
              name, val = uid_data

            else
              parse_error("unknown attribute `%s' for {%d}", token.value, n)
            end
            attr[name] = val
          end
          attr
        end
      end
      gmail_imap
    end
  end
end
