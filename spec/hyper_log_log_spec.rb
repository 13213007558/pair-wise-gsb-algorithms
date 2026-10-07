# frozen_string_literal: true

$LOAD_PATH << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'
require 'json'

class InjectedHyperLogLog < Containers::HyperLogLog
  def initialize(precision, hashes = {})
    @hashes = hashes
    super(precision)
  end

  def add(item)
    apply_hash(@hashes.fetch(item))
  end

  def force_dense!
    send(:convert_to_dense!)
  end
end

class MismatchedHashHyperLogLog < InjectedHyperLogLog
  protected

  def hash_configuration
    super.merge("seed" => 42)
  end
end

def controlled_hash(precision, index, rank)
  (index << (64 - precision)) | (1 << (64 - precision - rank))
end

def deterministic_values(count, seed)
  state = seed
  modulus = 1 << 31
  Array.new(count) do |index|
    state = (1103515245 * state + 12345) % modulus
    "set-#{seed}-#{index}-#{state.to_s(16)}"
  end
end

describe Containers::HyperLogLog do
  it "uses deterministic XXH64 with a fixed seed and UTF-8 tagged input" do
    sketch = described_class.new
    expect(format("%016x", sketch.send(:hash_bytes, "".b))).to eq("ef46db3751d8e999")
    expect(format("%016x", sketch.send(:hash_bytes, "abc".b))).to eq("44bc2cf5ad770999")
    expect(sketch.send(:hash_bytes, "abc".b)).to eq(described_class.new.send(:hash_bytes, "abc".b))
    expect(sketch.send(:hash_configuration)).to eq(
      "algorithm" => "XXH64",
      "seed" => 0,
      "encoding" => "UTF-8"
    )

    expect(sketch.send(:hash_bytes, sketch.send(:encode_item, "123"))).not_to eq(
      sketch.send(:hash_bytes, sketch.send(:encode_item, 123))
    )
    expect(sketch.send(:hash_bytes, sketch.send(:encode_item, :abc))).not_to eq(
      sketch.send(:hash_bytes, sketch.send(:encode_item, "abc"))
    )
  end

  it "returns zero for an empty sketch and validates precision" do
    sketch = described_class.new
    expect(sketch.estimate).to eq(0)
    expect(sketch.cardinality).to eq(0)
    expect(sketch.sparse?).to be true
    expect { described_class.new(3) }.to raise_error(ArgumentError)
    expect { described_class.new(19) }.to raise_error(ArgumentError)
  end

  it "stores controlled register values sparsely" do
    sketch = InjectedHyperLogLog.new(8, {
      1 => controlled_hash(8, 0, 2),
      2 => controlled_hash(8, 0, 5),
      3 => controlled_hash(8, 3, 1)
    }) 
    sketch.add(1)
    sketch.add(2)
    sketch.add(3)

    expected = Array.new(256, 0)
    expected[0] = 5
    expected[3] = 1
    expect(sketch.registers).to eq(expected)
    expect(sketch.sparse?).to be true
  end

  it "does not change registers or estimates when converting sparse state to dense state" do
    hashes = (0...100).to_h do |index|
      [index, controlled_hash(8, index, (index % 5) + 1)]
    end
    sparse = InjectedHyperLogLog.new(8, hashes)
    hashes.each_key { |item| sparse.add(item) }
    sparse_estimate = sparse.estimate
    sparse_registers = sparse.registers

    expect(sparse.sparse?).to be true
    sparse.force_dense!
    expect(sparse.dense?).to be true
    expect(sparse.registers).to eq(sparse_registers)
    expect(sparse.estimate).to eq(sparse_estimate)

    threshold_hashes = {}
    threshold = InjectedHyperLogLog.new(8, threshold_hashes)
    (0...256).each do |index|
      threshold_hashes[index] = controlled_hash(8, index, 1)
    end
    255.times { |index| threshold.add(index) }
    expect(threshold.sparse?).to be true
    threshold.add(255)
    expect(threshold.dense?).to be true
    expect(threshold.registers).to eq(Array.new(256, 1))
  end

  it "folds controlled high-precision registers to a lower precision" do
    source = InjectedHyperLogLog.new(10, {
      :a => controlled_hash(10, 0, 2),
      :b => controlled_hash(10, 1, 3),
      :c => controlled_hash(10, 3, 5),
      :d => controlled_hash(10, 4, 4),
      :e => controlled_hash(10, 7, 2),
      :missing_with_zero_suffix => controlled_hash(10, 10, 55)
    })
    %i[a b c d e missing_with_zero_suffix].each { |item| source.add(item) }
    source.force_dense!
    source.send(:fold!, 8)

    expected = InjectedHyperLogLog.new(8, {
      :a => controlled_hash(8, 0, 4),
      :b => controlled_hash(8, 0, 2),
      :c => controlled_hash(8, 0, 1),
      :d => controlled_hash(8, 1, 6),
      :e => controlled_hash(8, 1, 1),
      :missing_with_zero_suffix => controlled_hash(8, 2, 1)
    })
    %i[a b c d e missing_with_zero_suffix].each { |item| expected.add(item) }

    expect(source.precision).to eq(8)
    expect(source.registers).to eq(expected.registers)
  end

  it "merges arbitrary sparse and dense shards into the exact same register array" do
    values = deterministic_values(1000, 20261008)
    full = described_class.new(12)
    values.each { |value| full.add(value) }

    shards = Array.new(4) do |shard|
      sketch = InjectedHyperLogLog.new(12)
      values.each_with_index do |value, index|
        sketch.send(:apply_hash, sketch.send(:hash_bytes, sketch.send(:encode_item, value))) if index % 4 == shard
      end
      sketch.force_dense! if shard.even?
      sketch
    end.shuffle

    merged = shards[0].merge(shards[1]).merge!(shards[2]).merge(shards[3])
    expect(merged.registers).to eq(full.registers)
    expect(merged.estimate).to eq(full.estimate)
  end

  it "folds higher-precision shards while merging and never zero-pads upward" do
    values = deterministic_values(500, 20261009)
    full = described_class.new(10)
    values.each { |value| full.add(value) }

    low = described_class.new(10)
    high = described_class.new(12)
    values.each_with_index do |value, index|
      low.add(value) if index.even?
      high.add(value) if index.odd?
    end

    merged_high_first = high.merge(low)
    expect(merged_high_first.precision).to eq(10)
    expect(merged_high_first.registers).to eq(full.registers)

    merged_low_first = low.merge(high)
    expect(merged_low_first.precision).to eq(10)
    expect(merged_low_first.registers).to eq(full.registers)
    expect { low.send(:fold!, 12) }.to raise_error(ArgumentError)
  end

  it "round-trips sparse and dense versioned sketches" do
    sparse = described_class.new(8)
    10.times { |index| sparse.add("sparse-#{index}") }
    sparse_payload = JSON.parse(sparse.dump)
    expect(sparse_payload["format_version"]).to eq(1)
    expect(sparse_payload["representation"]).to eq("sparse")
    restored_sparse = described_class.load(sparse.dump)
    expect(restored_sparse.registers).to eq(sparse.registers)
    expect(restored_sparse.estimate).to eq(sparse.estimate)

    dense = InjectedHyperLogLog.new(8)
    256.times do |index|
      dense.send(:apply_hash, controlled_hash(8, index, (index % 5) + 1))
    end
    dense_payload = JSON.parse(dense.dump)
    expect(dense_payload["representation"]).to eq("dense")
    restored_dense = described_class.load(dense.dump)
    expect(restored_dense.dense?).to be true
    expect(restored_dense.registers).to eq(dense.registers)
    expect(restored_dense.estimate).to eq(dense.estimate)
  end

  it "rejects damaged serialized registers" do
    sketch = InjectedHyperLogLog.new(8)
    256.times do |index|
      sketch.send(:apply_hash, controlled_hash(8, index, 1))
    end

    expect { described_class.load("not json") }.to raise_error(ArgumentError)
    bad_version = JSON.parse(sketch.dump).merge("format_version" => 2)
    expect { described_class.load(JSON.generate(bad_version)) }.to raise_error(ArgumentError)
    bad_hash = JSON.parse(sketch.dump).tap { |payload| payload["hash"]["seed"] = 9 }
    expect { described_class.load(JSON.generate(bad_hash)) }.to raise_error(ArgumentError)
    bad_length = JSON.parse(sketch.dump).merge(
      "registers" => ["\x01".b * 255].pack("m0")
    )
    expect { described_class.load(JSON.generate(bad_length)) }.to raise_error(ArgumentError)
    bad_base64 = JSON.parse(sketch.dump)
    bad_base64["registers"] = "@" + bad_base64["registers"][1..]
    expect { described_class.load(JSON.generate(bad_base64)) }.to raise_error(ArgumentError)
    bad_rank = JSON.parse(sketch.dump).merge(
      "registers" => [("\x01".b * 255) + "\x3a".b].pack("m0")
    )
    expect { described_class.load(JSON.generate(bad_rank)) }.to raise_error(ArgumentError)

    sparse = described_class.new(8)
    sparse.add("one")
    corrupt_sparse = JSON.parse(sparse.dump)
    corrupt_sparse["registers"][0]["rank"] = 0
    expect { described_class.load(JSON.generate(corrupt_sparse)) }.to raise_error(ArgumentError)
    duplicate_sparse = JSON.parse(sparse.dump)
    duplicate_sparse["registers"] << duplicate_sparse["registers"].first
    expect { described_class.load(JSON.generate(duplicate_sparse)) }.to raise_error(ArgumentError)
  end

  it "rejects mismatched hash configuration and corrupt in-memory registers during merge" do
    good = described_class.new(8)
    good.add("one")
    mismatched = MismatchedHashHyperLogLog.new(8)
    expect { good.merge(mismatched) }.to raise_error(ArgumentError, /different hash/)

    corrupt_sparse = described_class.new(8)
    corrupt_sparse.instance_variable_set(:@registers, { 999 => 1 })
    expect { good.merge(corrupt_sparse) }.to raise_error(ArgumentError, /corrupt/)

    corrupt_dense = described_class.new(8)
    corrupt_dense.instance_variable_set(:@dense, true)
    corrupt_dense.instance_variable_set(:@registers, "\xff".b * 256)
    expect { good.merge(corrupt_dense) }.to raise_error(ArgumentError, /corrupt/)
  end

  it "keeps estimation error distributed around the true cardinality with fixed input seeds" do
    cardinalities = [50, 250, 1000, 5000, 20000]
    errors = cardinalities.flat_map do |cardinality|
      8.times.map do |group|
        sketch = described_class.new(12)
        deterministic_values(cardinality, 20261008 + group * 7919).each do |value|
          sketch.add(value)
        end
        (sketch.estimate - cardinality).abs / cardinality.to_f
      end
    end

    expect(errors.count { |error| error <= 0.10 }).to be >= 38
    expect(errors.all? { |error| error <= 0.20 }).to be true
    expect(errors.sort[errors.size / 2]).to be <= 0.05
  end
end
