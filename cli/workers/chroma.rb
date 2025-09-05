# frozen_string_literal: true

module NittyMail
  module Workers
    module Chroma
      module_function

      # Returns a Set of existing document IDs present in Chroma.
      # Uses batched id lookups with a small worker pool for performance.
      def existing_ids(collection:, candidate_ids:, threads: 4, batch_size: 1000)
        id_queue = Queue.new
        Array(candidate_ids).each_slice(batch_size) { |slice| id_queue << slice }

        existing = Set.new
        mutex = Mutex.new

        worker_count = threads.to_i
        worker_count = 1 if worker_count < 1
        workers = Array.new(worker_count) do
          Thread.new do
            until id_queue.empty?
              id_batch = begin
                id_queue.pop(true)
              rescue ThreadError
                break
              end
              begin
                embeddings = begin
                  collection.get(ids: id_batch, include: [])
                rescue ArgumentError, NoMethodError
                  collection.get(ids: id_batch)
                end
                ids = embeddings.map(&:id)
                mutex.synchronize { ids.each { |i| existing << i } }
              rescue => e
                # Log and continue to allow other batches to proceed
                first = nil
                last = nil
                begin
                  first = id_batch.first
                  last = id_batch.last
                rescue
                end
                warn "chroma existing_ids error: #{e.class}: #{e.message} ids=#{first}..#{last}"
              end
            end
          end
        end
        workers.each(&:join)

        existing
      end
    end
  end
end
