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

require "ruby-progressbar"

module NittyMail
  module Reporting
    class BaseReporter
      def initialize(quiet: false, on_progress: nil)
        @quiet = !!quiet
        @on_progress = on_progress
      end

      # Single reporting hook
      # type: Symbol, payload: Hash
      def event(type, payload = {})
        # Default: forward simple progress
        if type.to_sym == :enrich_progress || type.to_sym == :embed_batch_written
          current = payload[:current]
          total = payload[:total]
          if current && total
            @on_progress&.call(current, total)
          end
        end
      end

      # Back-compat shim for callers still using log(message)
      def log(message)
        event(:log, {message: message.to_s})
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
      def initialize(**kwargs)
        super
        @bars = {}
        @current_mailbox = nil
      end

      def event(type, payload = {})
        case type.to_sym
        when :preflight_started
          create_bar(:preflight, "preflight", payload[:total_mailboxes])
        when :preflight_mailbox
          tick(:preflight, 1)
          log(:preflight, format_payload(type, payload))
        when :preflight_finished
          finish(:preflight)
        when :mailbox_started
          @current_mailbox = payload[:mailbox]
          create_bar(:mailbox, "#{payload[:mailbox]} (UIDVALIDITY=#{payload[:uidvalidity]})", payload[:total])
        when :sync_message_processed
          tick(:mailbox, 1)
        when :mailbox_finished
          finish(:mailbox)
        when :mailbox_summary
          say(format_payload(type, payload))
        when :mailbox_skipped
          say("skipped mailbox #{payload[:mailbox]}: #{payload[:reason]}")
        when :sync_log
          log(:mailbox, payload[:message])
        when :pruned_missing, :prune_none, :prune_skipped_due_to_abort, :prune_candidates_present, :purge_old_validity, :purge_skipped
          say(format_payload(type, payload))
        when :embed_started
          create_bar(:embed, "embed", payload[:estimated_jobs])
        when :embed_batch_written
          tick(:embed, payload[:count].to_i)
        when :embed_status, :embed_error, :embed_skipped, :embed_regenerate, :embed_db_error, :embed_interrupted_log
          log(:embed, format_payload(type, payload))
        when :embed_finished, :embed_interrupted
          finish(:embed)
        when :embed_scan_started
          say(format_payload(type, payload))
        when :enrich_started
          create_bar(:enrich, "enrich", payload[:total].to_i)
        when :enrich_progress
          tick(:enrich, payload[:delta].to_i)
        when :enrich_error
          log(:enrich, format_payload(type, payload))
        when :enrich_finished, :enrich_interrupted
          finish(:enrich)
        when :db_checkpoint_complete
          say("DB checkpoint complete (#{payload[:mode]})")
        else
          # Fallback: print event
          say(format_payload(type, payload))
        end
      end

      private

      def create_bar(key, title, total)
        finish(key) if @bars[key]
        @bars[key] = ProgressBar.create(title: title.to_s, total: total.to_i, format: "%t: |%B| %p%% (%c/%C) [%e]")
      end

      def tick(key, step)
        bar = @bars[key]
        bar&.progress = [bar.progress + step, bar.total].min if bar
      end

      def finish(key)
        bar = @bars.delete(key)
        bar&.finish
      end

      def log(key, msg)
        bar = @bars[key]
        bar ? bar.log(msg.to_s) : say(msg)
      end

      def say(msg)
        puts(msg) unless @quiet
      end

      def format_payload(type, payload)
        label = type.to_s.tr("_", " ")
        attrs = payload.map { |k, v| "#{k}=#{v}" }.join(" ")
        "#{label}: #{attrs}"
      end
    end

    # Text reporter: prints one-line messages, no progress bars
    class TextReporter < BaseReporter
      def initialize(**kwargs)
        super
      end

      def event(type, payload = {})
        case type.to_sym
        when :enrich_progress
          say("enrich progress: current=#{payload[:current]} total=#{payload[:total]} delta=#{payload[:delta]}")
        when :embed_batch_written
          say("embed batch written: count=#{payload[:count]}")
        else
          say(format_payload(type, payload))
        end
      end

      private

      def say(msg)
        puts(msg) unless @quiet
      end

      def format_payload(type, payload)
        label = type.to_s.tr("_", " ")
        attrs = payload.map { |k, v| "#{k}=#{v}" }.join(" ")
        "#{label}: #{attrs}"
      end
    end
  end
end
