$LOAD_PATH << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

class ControlledHyperLogLog < Containers::HyperLogLog
  def initialize(precision, controlled_hashes)
    super(precision)
    @controlled_hashes = controlled_hashes
  end

  private

  def hash_element(element)
    @controlled_hashes.fetch(element)
  end
end

class IncompatibleHyperLogLog < ControlledHyperLogLog
  def hash_algorithm
    "ProcessHash"
  end

  def hash_seed
    123
  end
end

def controlled_hash(register_index, rank, precision)
  (register_index << (32 - precision)) | (1 << (rank - 1))
end

def controlled_rank_hash(register_index, rank, precision)
  hash_value = register_index << (32 - precision)
  return hash_value if rank == (32 - precision + 1)
  bit_position = rank - 1
  hash_value | (1 << bit_position)
end

describe Containers::HyperLogLog do
  it "uses the fixed MurmurHash3 algorithm, seed, and byte order" do
    sketch = described_class.new(8)

    expect(sketch.send(:murmur3_32, "".b, 0)).to eq(0)
    expect(sketch.send(:murmur3_32, "hello".b, 0)).to eq(613_153_351)
    expect(sketch.send(:murmur3_32, "hello".b, described_class::HASH_SEED)).to eq(1_568_626_408)
    expect(sketch.hash_seed).to eq(0x9747b28c)
  end

  it "returns zero for an empty sketch before and after restoration" do
    sketch = described_class.new(8)

    expect(sketch.estimate).to eq(0)
    expect(Containers::HyperLogLog.load(sketch.dump).estimate).to eq(0)
  end

  it "stores injected hashes in the expected registers" do
    hashes = {
      first: controlled_hash(0, 1, 4),
      second: controlled_hash(5, 4, 4),
      third: controlled_hash(15, 17, 4)
    }
    sketch = ControlledHyperLogLog.new(4, hashes)
    hashes.each_key { |key| sketch.add(key) }

    expected = [1, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 17]
    expect(sketch.registers).to eq(expected)
    expect(sketch.sparse?).to be(true)
  end

  it "keeps estimates and registers unchanged when converting sparse storage to dense" do
    hashes = (0...4).each_with_object({}) do |index, values|
      values[index] = controlled_hash(index, 3 + (index % 2), 8)
    end
    sketch = ControlledHyperLogLog.new(8, hashes)
    hashes.each_key { |key| sketch.add(key) }

    sparse_registers = sketch.registers
    sparse_estimate = sketch.estimate
    sketch.send(:densify)

    expect(sketch.sparse?).to be(false)
    expect(sketch.registers).to eq(sparse_registers)
    expect(sketch.estimate).to eq(sparse_estimate)
  end

  it "folds higher-precision registers into lower-precision registers" do
    high_hashes = {
      0 => controlled_rank_hash(0, 24, 6),
      1 => controlled_rank_hash(2, 3, 6)
    }
    low_hashes = {
      0 => controlled_hash(0, 3, 4),
      1 => controlled_hash(1, 4, 4)
    }
    high = ControlledHyperLogLog.new(6, high_hashes)
    low = ControlledHyperLogLog.new(4, low_hashes)
    high_hashes.each_key { |key| high.add(key) }
    low_hashes.each_key { |key| low.add(key) }

    low.merge!(high)

    expect(low.registers).to eq([24, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
  end

  it "folds ranks using extra index bits" do
    high_hashes = {
      0 => 0,
      1 => (1 << 28) | (1 << 24)
    }
    high = ControlledHyperLogLog.new(6, high_hashes)
    high_hashes.each_key { |key| high.add(key) }
    low = ControlledHyperLogLog.new(4, {})

    low.merge!(high)

    expect(low.registers).to eq([29, 25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
  end

  it "merges same-precision shards into exactly the same registers as adding every value" do
    precision = 12
    universe_size = 5000
    direct = described_class.new(precision)
    shards = Array.new(5) { described_class.new(precision) }

    universe_size.times do |index|
      value = "user-#{index}"
      direct.add(value)
      shards[index % 5].add(value)
    end

    merged = shards.first.dup
    shards.drop(1).reverse_each { |shard| merged.merge!(shard) }

    expect(merged.registers).to eq(direct.registers)
    expect(merged.estimate).to eq(direct.estimate)
  end

  it "folds arbitrary higher-precision shards into the same low-precision registers" do
    universe_size = 1000
    direct = described_class.new(10)
    shards = Array.new(3) { described_class.new(14) }

    universe_size.times do |index|
      value = "fold-user-#{index}"
      direct.add(value)
      shards[index % 3].add(value)
    end

    merged = direct.class.new(10)
    [2, 0, 1].each { |index| merged.merge!(shards[index]) }

    expect(merged.precision).to eq(10)
    expect(merged.registers).to eq(direct.registers)
    expect(merged.estimate).to eq(direct.estimate)
  end

  it "uses fixed UTF-8 byte encoding and rejects unsupported element types" do
    left = described_class.new(10)
    right = described_class.new(10)
    value = "héllo".dup.force_encoding(Encoding::UTF_8)

    left.add(value)
    right.add(value)

    expect(left.registers).to eq(right.registers)
    expect { left.add(Object.new) }.to raise_error(TypeError)
    expect { described_class.new(10).add("\xFF".b) }.to raise_error(ArgumentError)
  end

  it "rejects precision outside the supported range" do
    expect { described_class.new(3) }.to raise_error(ArgumentError)
    expect { described_class.new(17) }.to raise_error(ArgumentError)
  end

  it "rejects incompatible hash configurations and precision upgrades" do
    sketch = described_class.new(8)
    incompatible = IncompatibleHyperLogLog.new(8, {})
    lower_precision = described_class.new(6)
    damaged = described_class.new(8)
    damaged.instance_variable_set(:@dense, [99] * 256)

    expect { sketch.merge!(incompatible) }.to raise_error(ArgumentError, /different hash/)
    expect { sketch.merge!(lower_precision) }.to raise_error(ArgumentError, /lower precision/)
    expect { sketch.merge!(damaged) }.to raise_error(Containers::HyperLogLog::Error, /corrupt/)
  end

  it "saves and restores sparse and dense sketches with a versioned binary format" do
    sparse = described_class.new(8)
    sparse.add("one")
    dense = described_class.new(4)
    8.times { |index| dense.add("dense-#{index}") }

    restored_sparse = described_class.load(sparse.dump)
    restored_dense = described_class.load(dense.dump)

    expect(restored_sparse.precision).to eq(8)
    expect(restored_sparse.sparse?).to be(true)
    expect(restored_sparse.registers).to eq(sparse.registers)
    expect(restored_dense.precision).to eq(4)
    expect(restored_dense.sparse?).to be(false)
    expect(restored_dense.registers).to eq(dense.registers)
    expect(sparse.dump.byteslice(4, 1)).to eq([described_class::FORMAT_VERSION].pack("C"))
  end

  it "round-trips through binary IO" do
    sketch = described_class.new(10)
    100.times { |index| sketch.add("io-#{index}") }
    io = StringIO.new

    sketch.save(io)
    io.rewind
    restored = described_class.load(io)

    expect(restored.registers).to eq(sketch.registers)
    expect(restored.estimate).to eq(sketch.estimate)
  end

  it "rejects damaged, truncated, trailing, or incompatible serialized data" do
    sketch = described_class.new(4)
    sketch.add("dense")
    sketch.instance_variable_set(:@dense, Array.new(16, 1))
    sketch.instance_variable_set(:@sparse, {})
    dense_data = sketch.dump

    sparse = described_class.new(4)
    sparse.add("sparse")
    sparse_data = sparse.dump
    sparse_duplicate = sparse_data.dup
    sparse_duplicate.setbyte(19, 0)

    damaged_dense = dense_data.dup
    damaged_dense.setbyte(-1, 255)
    bad_version = dense_data.dup
    bad_version.setbyte(4, 2)
    bad_magic = dense_data.dup
    bad_magic.setbyte(0, 'X'.ord)
    bad_seed = dense_data.dup
    bad_seed.setbyte(7, 255)

    expect { described_class.load(damaged_dense) }.to raise_error(described_class::Error, /corrupt/)
    expect { described_class.load(dense_data.byteslice(0...-1)) }.to raise_error(described_class::Error, /truncated|corrupt/)
    expect { described_class.load(dense_data + "extra") }.to raise_error(described_class::Error, /corrupt/)
    expect { described_class.load(sparse_duplicate) }.to raise_error(described_class::Error, /corrupt/)
    expect { described_class.load(bad_version) }.to raise_error(described_class::Error, /format version/)
    expect { described_class.load(bad_magic) }.to raise_error(described_class::Error, /magic/)
    expect { described_class.load(bad_seed) }.to raise_error(described_class::Error, /seed/)
  end

  it "keeps hashes stable across separate processes" do
    script = <<~RUBY
      require 'algorithms'
      sketch = Containers::HyperLogLog.new(10)
      ["alpha", "beta", 42, :omega].each { |value| sketch.add(value) }
      $stdout.binmode.write(sketch.dump)
    RUBY
    first = IO.popen([RbConfig.ruby, "-Ilib", "-e", script], &:read)
    second = IO.popen([RbConfig.ruby, "-Ilib", "-e", script], &:read)

    expect(first).to eq(second)
  end

  it "keeps the fixed-seed estimation error small across independent sets" do
    group_count = 8
    cardinality = 10_000
    errors = group_count.times.map do |group|
      sketch = described_class.new(14)
      offset = group * cardinality
      cardinality.times do |index|
        sketch.add("distribution-#{offset + index}")
      end
      (sketch.estimate - cardinality).abs.to_f / cardinality
    end

    expect(errors.max).to be < 0.08
    expect(errors.count { |error| error < 0.02 }).to be >= 6
    expect(errors.sum / errors.length).to be < 0.02
  end
end
