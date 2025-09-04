# frozen_string_literal: true

require "chroma-db"
require_relative "../utils/enricher"

module NittyMail
  module Workers
    class Consumer
      def initialize(collection:, job_queue:, interrupted:, on_progress:, on_error:)
        @collection = collection
        @job_queue = job_queue
        @interrupted = interrupted # -> bool
        @on_progress = on_progress # -> proc(count)
        @on_error = on_error       # -> proc(failed_count, exception, id_range)
      end

      def start(threads: 1)
        count = threads.to_i
        count = 1 if count < 1
        Array.new(count) do
          Thread.new do
            until @interrupted.call
              upload_job = @job_queue.pop
              break if upload_job.equal?(:__END__)

              id_batch, doc_batch, meta_batch = upload_job
              begin
                embeddings = id_batch.each_with_index.map do |idv, idx|
                  norm_doc = NittyMail::Enricher.normalize_utf8(doc_batch[idx])
                  norm_meta = normalize_meta(meta_batch[idx])
                  ::Chroma::Resources::Embedding.new(id: idv, document: norm_doc, metadata: norm_meta)
                end
                @collection.add(embeddings)
                @on_progress&.call(embeddings.size)
              rescue => e
                id_range = [id_batch.first, id_batch.last]
                @on_error&.call(id_batch.size, e, id_range)
              end
            end
          end
        end
      end

      private

      def normalize_meta(meta)
        out = {}
        meta.to_h.each do |k, v|
          out[k] = case v
          when String
            NittyMail::Enricher.normalize_utf8(v)
          when Array
            v.map { |x| x.is_a?(String) ? NittyMail::Enricher.normalize_utf8(x) : x }
          else
            v
          end
        end
        out
      end
    end
  end
end
