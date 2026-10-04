$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::XorFilter do
  # FNV-1a 64-bit over the key's string form, seeded as required by the API.
  let(:hash_fn) do
    ->(key, seed) do
      hash = 0xcbf29ce484222325 ^ (seed * 0x100000001b3)
      key.to_s.each_byte do |byte|
        hash = ((hash ^ byte) * 0x100000001b3) & 0xffffffffffffffff
      end
      hash
    end
  end
  let(:rng) { Random.new(42) }
  let(:keys) { (1..1_000).map { |i| "key-#{i}" } }
  let(:filter) { described_class.new(keys, hash_fn: hash_fn, rng: rng) }

  describe '.new' do
    it 'contains every inserted key (no false negatives)' do
      keys.each { |key| expect(filter.contains?(key)).to be(true) }
    end

    it 'reports its size' do
      expect(filter.size).to eq(keys.length)
      expect(filter).not_to be_empty
    end

    it 'builds an empty filter from no keys' do
      empty = described_class.new([], hash_fn: hash_fn)
      expect(empty).to be_empty
      expect(empty.contains?('anything')).to be(false)
    end

    it 'requires a callable hash_fn' do
      expect { described_class.new(keys, hash_fn: nil) }.to raise_error(ArgumentError)
    end

    it 'requires a positive max_attempts' do
      expect { described_class.new(keys, hash_fn: hash_fn, max_attempts: 0) }.to raise_error(ArgumentError)
    end
  end

  describe 'false positive rate' do
    it 'stays near 1/256 for absent keys' do
      absent = (1..20_000).map { |i| "absent-#{i}" }
      hits = absent.count { |key| filter.contains?(key) }
      rate = hits.to_f / absent.length
      expect(rate).to be > 0
      expect(rate).to be < 0.01
    end
  end

  describe 'construction retries' do
    it 'retries with a new seed when a seed yields an unpeelable graph' do
      # The first seed drawn (0) makes every key hash identically, which cannot
      # be peeled; later seeds hash normally.
      flaky_hash = ->(key, seed) { seed.zero? ? 1234 : hash_fn.call(key, seed) }
      scripted_rng = Object.new
      draws = [0, 7, 7, 7]
      scripted_rng.define_singleton_method(:rand) { |_n| draws.shift || 7 }

      built = described_class.new(keys, hash_fn: flaky_hash, rng: scripted_rng)
      expect(built.attempts).to eq(2)
      keys.each { |key| expect(built.contains?(key)).to be(true) }
    end

    it 'raises ConstructionError when the hash stays degenerate beyond max_attempts' do
      constant_hash = ->(_key, _seed) { 42 }
      expect {
        described_class.new(keys, hash_fn: constant_hash, rng: Random.new(1), max_attempts: 5)
      }.to raise_error(Containers::XorFilter::ConstructionError, /5 attempts/)
    end

    it 'never drops inserted keys with weak but distinct hashes' do
      # Sequential hashes have almost no entropy of their own; the filter must
      # still build and contain every key.
      sequential_hash = ->(key, seed) { key.to_s.delete("key-").to_i + seed }
      built = described_class.new(keys, hash_fn: sequential_hash, rng: Random.new(9))
      keys.each { |key| expect(built.contains?(key)).to be(true) }
    end

    it 'raises ConstructionError for duplicate keys, whose hashes cancel out' do
      duplicates = keys + keys.first(3)
      expect {
        described_class.new(duplicates, hash_fn: hash_fn, rng: Random.new(2), max_attempts: 4)
      }.to raise_error(Containers::XorFilter::ConstructionError)
    end
  end

  describe 'serialization' do
    it 'dumps deterministically for identical inputs' do
      a = described_class.new(keys, hash_fn: hash_fn, rng: Random.new(42))
      b = described_class.new(keys, hash_fn: hash_fn, rng: Random.new(42))
      expect(a.dump).to eq(b.dump)
    end

    it 'round-trips through dump/load preserving membership answers' do
      restored = described_class.load(filter.dump, hash_fn: hash_fn)
      expect(restored).to eq(filter)
      expect(restored.size).to eq(keys.length)
      keys.each { |key| expect(restored.contains?(key)).to be(true) }
      expect(restored.contains?('absent-1')).to eq(filter.contains?('absent-1'))
    end

    it 'serializes empty filters' do
      empty = described_class.new([], hash_fn: hash_fn)
      restored = described_class.load(empty.dump, hash_fn: hash_fn)
      expect(restored).to be_empty
      expect(restored.contains?('anything')).to be(false)
    end

    it 'rejects foreign payloads' do
      expect { described_class.load(Marshal.dump(['nope']), hash_fn: hash_fn) }.to raise_error(ArgumentError)
    end
  end
end
