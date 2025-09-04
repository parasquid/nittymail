# frozen_string_literal: true

require "spec_helper"
require_relative "../../workers/chroma"

DummyEmbedding = Struct.new(:id)

class DummyCollection
  def initialize(existing_ids: Set.new, error_batches: Set.new)
    @existing_ids = existing_ids
    @error_batches = error_batches
    @batch_counter = 0
  end

  # Simulate Chroma get API; we only care about ids lookups
  def get(ids: nil, **_opts)
    @batch_counter += 1
    raise StandardError, "boom" if @error_batches.include?(@batch_counter)
    ids = Array(ids)
    present = ids.select { |i| @existing_ids.include?(i) }
    present.map { |i| DummyEmbedding.new(i) }
  end
end

RSpec.describe NittyMail::Workers::Chroma do
  Given(:all_ids) { Array.new(2500) { |i| "3:#{1000 + i}" } }
  Given(:existing_subset) { all_ids.sample(600).to_set }
  Given(:collection) { DummyCollection.new(existing_ids: existing_subset) }

  context "batched id lookups" do
    Given(:result) do
      described_class.existing_ids(collection: collection, candidate_ids: all_ids, threads: 3, batch_size: 200)
    end

    Then { result.is_a?(Set) }
    Then { (result - existing_subset).empty? }
    Then { (existing_subset - result).empty? }
  end

  context "tolerates per-batch errors" do
    Given(:errorful_collection) { DummyCollection.new(existing_ids: existing_subset, error_batches: Set[2, 5]) }
    Given(:result) do
      described_class.existing_ids(collection: errorful_collection, candidate_ids: all_ids, threads: 4, batch_size: 150)
    end

    Then { result.subset?(existing_subset) }
    And { result.size <= existing_subset.size }
  end
end
