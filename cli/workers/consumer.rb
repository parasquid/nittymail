# frozen_string_literal: true

require "chroma-db"

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
                  Chroma::Resources::Embedding.new(id: idv, document: doc_batch[idx], metadata: meta_batch[idx])
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
    end
  end
end

