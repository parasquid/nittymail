# frozen_string_literal: true

# Disable all external network connections in tests by default,
# similar in spirit to WebMock.disable_net_connect!.
#
# Allow network explicitly by setting ALLOW_NET=1 or when recording
# integration cassettes (INTEGRATION_RECORD=1).

if !ENV["ALLOW_NET"] && !ENV["INTEGRATION_RECORD"]
  module NetworkBlocker
    class BlockedConnectionError < StandardError; end

    def self.blocking_message(host, port)
      "External network connections are disabled in tests: attempted #{host}:#{port}. Set ALLOW_NET=1 to allow."
    end

    def self.wrap_tcp_methods!
      return if defined?(@@wrapped) && @@wrapped
      @@wrapped = true

      require "socket"

      class << ::TCPSocket
        alias_method :__nm_orig_open, :open
        alias_method :__nm_orig_new, :new

        def open(host, port, *args)
          raise NetworkBlocker::BlockedConnectionError, NetworkBlocker.blocking_message(host, port)
        end

        def new(host, port, *args)
          raise NetworkBlocker::BlockedConnectionError, NetworkBlocker.blocking_message(host, port)
        end
      end

      if ::Socket.respond_to?(:tcp)
        class << ::Socket
          alias_method :__nm_orig_tcp, :tcp
          def tcp(host, port, *args)
            raise NetworkBlocker::BlockedConnectionError, NetworkBlocker.blocking_message(host, port)
          end
        end
      end
    end
  end

  NetworkBlocker.wrap_tcp_methods!
end

