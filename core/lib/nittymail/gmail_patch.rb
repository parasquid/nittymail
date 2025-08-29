# frozen_string_literal: true

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
