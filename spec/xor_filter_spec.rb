$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'
require 'digest'

describe Containers::XorFilter do
  let(:hash) do
    ->(key) { Digest::SHA256.digest(key.to_s).unpack1("Q>") }
  end

  it 'builds a read-only filter that contains every inserted key' do
    keys = Array(1..10_000)
    filter = described_class.new(keys, hash: hash, random: Random.new(20260204))

    expect(keys.all? { |key| filter.contains?(key) }).to be true
    expect(filter).to be_frozen
    expect { filter.instance_variable_set(:@seed, 0) }.to raise_error(FrozenError)
  end

  it 'supports include?, member?, and [] aliases' do
    filter = described_class.new([7, 13], hash: hash, random: Random.new(99))

    expect(filter.include?(7)).to be true
    expect(filter.member?(13)).to be true
    expect(filter[7]).to be true
  end

  it 'retries with new seeds and raises after the configured limit' do
    attempts = 0
    random = Object.new
    random.define_singleton_method(:rand) do |range|
      attempts += 1
      range - 1
    end

    expect {
      described_class.new([1, 2, 3], hash: ->(_key) { 42 }, random: random, max_attempts: 5)
    }.to raise_error(described_class::ConstructionError, /after 5 attempts/)
    expect(attempts).to eq(5)
  end

  it 'fails immediately when a degenerate hash cannot be peeled with one attempt' do
    random = double(rand: 0)

    expect {
      described_class.new([1, 2], hash: ->(_key) { 11 }, random: random, max_attempts: 1)
    }.to raise_error(described_class::ConstructionError, /after 1 attempt/)
    expect(random).to have_received(:rand).once
  end

  it 'uses a replacement seed after a degenerate seed fails to peel' do
    attempts = 0
    failing_seed = 177
    random = Object.new
    random.define_singleton_method(:rand) do |range|
      attempts += 1
      attempts == 1 ? failing_seed : failing_seed + 1
    end
    keys = Array(1..100)
    filter = described_class.new(keys, hash: hash, random: random, max_attempts: 2)

    expect(attempts).to eq(2)
    expect(keys.all? { |key| filter.contains?(key) }).to be true
  end

  it 'has a low false-positive rate for keys outside the set' do
    keys = Array.new(10_000) { |index| index + 1 }
    filter = described_class.new(keys, hash: hash, random: Random.new(4096))
    absent_keys = Array.new(100_000) { |index| 10_001 + index }
    false_positives = absent_keys.count { |key| filter.contains?(key) }

    expect(false_positives.to_f / absent_keys.length).to be < 0.01
  end

  it 'serializes and restores a stable, binary representation' do
    random = Random.new(1234)
    keys = %w[alpha beta gamma delta].freeze
    filter = described_class.new(keys, hash: hash, random: random)
    restored = described_class.from_binary(filter.to_binary, hash: hash)
    rebuilt = described_class.new(keys, hash: hash, random: Random.new(1234))

    expect(filter.to_binary.encoding).to eq(Encoding::BINARY)
    expect(filter.to_binary).to eq(rebuilt.to_binary)
    expect(restored.to_binary).to eq(filter.to_binary)
    expect(restored.seed).to eq(filter.seed)
    expect(restored.size).to eq(filter.size)
    keys.each do |key|
      expect(restored.contains?(key)).to be true
      expect(restored[key]).to eq(filter.contains?(key))
    end
  end

  it 'rejects corrupt serialized data' do
    filter = described_class.new([1], hash: hash, random: Random.new(7))
    data = filter.to_binary.dup
    data.setbyte(0, 0x00)

    expect {
      described_class.from_binary(data, hash: hash)
    }.to raise_error(ArgumentError)
  end

  it 'supports an empty set without false positives' do
    filter = described_class.new([], hash: hash, random: Random.new(1))

    expect(filter.contains?(:anything)).to be false
    expect(filter.size).to eq(0)
    expect(filter.to_binary.bytesize).to eq(24)
    expect(described_class.from_binary(filter.to_binary, hash: hash).contains?(0)).to be false
  end

  it 'does not freeze the string passed to from_binary' do
    filter = described_class.new([1], hash: hash, random: Random.new(5))
    data = filter.to_binary.dup

    described_class.from_binary(data, hash: hash)

    expect(data).not_to be_frozen
  end

  it 'rejects duplicate keys and invalid construction options' do
    expect {
      described_class.new([1, 1], hash: hash, random: Random.new(1))
    }.to raise_error(ArgumentError, /unique/)
    expect {
      described_class.new([1], hash: nil, random: Random.new(1))
    }.to raise_error(ArgumentError, /hash/)
    expect {
      described_class.new([1], hash: hash, random: Object.new)
    }.to raise_error(ArgumentError, /random/)
    expect {
      described_class.new([1], hash: hash, random: Random.new(1), max_attempts: 0)
    }.to raise_error(ArgumentError, /max_attempts/)
  end

  it 'uses approximately 1.23 fingerprints per inserted key' do
    keys = Array(1..10_000)
    filter = described_class.new(keys, hash: hash, random: Random.new(42))

    expect((filter.to_binary.bytesize - 24).to_f / keys.length).to be_between(1.23, 1.25)
  end

  it 'accepts negative integer hashes as unsigned 64-bit values' do
    filter = described_class.new([-1, 0, 1], hash: ->(key) { key }, random: Random.new(3))

    expect(filter.contains?(-1)).to be true
    expect(filter.contains?(0)).to be true
    expect(filter.contains?(1)).to be true
  end
end
