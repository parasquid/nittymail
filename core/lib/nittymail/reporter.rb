# frozen_string_literal: true

require "ruby-progressbar"

module NittyMail
  module Reporting
    class BaseReporter
      attr_reader :total, :current

      def initialize(quiet: false, on_progress: nil)
        @quiet = !!quiet
        @on_progress = on_progress
        @total = 0
        @current = 0
      end

      def start(title:, total: 0)
        @total = total.to_i
        @current = 0
      end

      def increment(step = 1)
        @current += step.to_i
        @on_progress&.call(@current, @total)
      end

      def log(message)
      end

      def info(message)
      end

      def warn(message)
      end

      def finish
      end
    end

    # No-op reporter suitable for library usage (no stdout by default)
    class NullReporter < BaseReporter
      def warn(message)
        # Send warnings to stderr to aid debugging in dev, but remain minimal
        # Comment out to fully silence: $stderr.puts(message)
      end
    end

    # CLI reporter using ruby-progressbar and stdout logging
    class CLIReporter < BaseReporter
      def start(title:, total: 0)
        super
        @bar = ProgressBar.create(title: title.to_s, total: @total, format: "%t: |%B| %p%% (%c/%C) [%e]")
      end

      def increment(step = 1)
        super
        @bar&.progress = @current if @bar
      end

      def log(message)
        @bar ? @bar.log(message.to_s) : info(message)
      end

      def info(message)
        puts(message) unless @quiet
      end

      def warn(message)
        Kernel.warn(message)
      end

      def finish
        @bar&.finish
      end
    end
  end
end
