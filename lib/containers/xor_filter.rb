=begin rdoc
    An Xor filter is a compact, read-only probabilistic membership structure. It is built
    in bulk from a fixed set of unique keys and afterwards answers contains? queries in
    O(1) time with no false negatives (every inserted key is reported present) and a
    small false positive rate (about 1/256 for 8-bit fingerprints) for keys that were
    never inserted.

    Compared to a Bloom filter it uses less space (~1.23n slots of 1 byte each) and is
    faster to query, but it cannot be modified after construction.

    Based on "Xor Filters: Faster and Smaller Than Bloom and Cuckoo Filters"
    (Thomas Mueller Graf, Daniel Lemire, 2019).

    The caller supplies the key hash function and the random source:

      hash_fn = ->(key, seed) { ... }   # must return an Integer, mixed with +seed+
      rng     = Random.new(42)          # any object responding to #rand like Random

      filter = Containers::XorFilter.new(%w[foo bar baz], hash_fn: hash_fn, rng: rng)
      filter.contains?("foo") #=> true
      filter.contains?("qux") #=> false (with high probability)

    Construction peels a random hypergraph; if a seed produces a graph that cannot be
    fully peeled, a new seed is drawn from +rng+ and construction is retried, up to
    +max_attempts+ times, after which Containers::XorFilter::ConstructionError is raised.
    A successfully built filter is guaranteed to contain every inserted key.

    Serialization is stable: #dump returns a deterministic byte string for a given
    (keys, hash_fn, rng) combination, and XorFilter.load restores it. The hash function
    cannot be serialized, so it must be supplied again when loading:

      blob   = filter.dump
      filter = Containers::XorFilter.load(blob, hash_fn: hash_fn)
=end
class Containers::XorFilter
  # Raised when the construction graph cannot be peeled within +max_attempts+ seeds.
  class ConstructionError < StandardError; end

  VERSION = 1
  MAGIC = "XRBF"
  MASK64 = (1 << 64) - 1
  FINGERPRINT_MASK = 0xff
  # Table size factor from the paper: ~1.23n slots plus a constant for small inputs.
  SIZE_FACTOR = 1.23
  SIZE_OFFSET = 32
  DEFAULT_MAX_ATTEMPTS = 64

  # The number of keys the filter was built from.
  attr_reader :size
  # The seed that produced a peelable graph. Stored so the filter can be serialized.
  attr_reader :seed
  # How many seeds were tried before construction succeeded.
  attr_reader :attempts

  # Builds a filter from +keys+, which must be unique. Duplicate keys (or keys
  # whose 64-bit hashes collide) cancel each other in the construction graph,
  # so construction cannot peel it and raises ConstructionError after
  # +max_attempts+ seeds rather than returning an incomplete filter.
  #
  #   hash_fn:      required callable, invoked as hash_fn.call(key, seed), must return
  #                 an Integer. Only the low 64 bits are used.
  #   rng:          random source used to draw construction seeds; anything responding
  #                 to #rand like Random. Defaults to Random.new.
  #   max_attempts: maximum number of seeds to try before raising ConstructionError.
  def initialize(keys, hash_fn:, rng: Random.new, max_attempts: DEFAULT_MAX_ATTEMPTS)
    raise ArgumentError, "hash_fn must respond to #call" unless hash_fn.respond_to?(:call)
    raise ArgumentError, "rng must respond to #rand" unless rng.respond_to?(:rand)
    raise ArgumentError, "max_attempts must be positive" unless max_attempts.to_i > 0

    @hash_fn = hash_fn
    keys = keys.to_a
    @size = keys.length
    @attempts = 0

    if keys.empty?
      @seed = 0
      @block_length = 0
      @fingerprints = []
      return
    end

    capacity = SIZE_OFFSET + (SIZE_FACTOR * keys.length).ceil
    @block_length = capacity / 3

    @fingerprints = nil

    max_attempts.to_i.times do
      @attempts += 1
      seed = rng.rand(1 << 32)
      hashes = keys.map { |key| @hash_fn.call(key, seed).to_i & MASK64 }
      fingerprints = try_build(hashes)
      if fingerprints
        @seed = seed
        @fingerprints = fingerprints
        break
      end
    end

    unless @fingerprints
      raise ConstructionError,
            "could not peel construction graph for #{keys.length} keys within #{max_attempts} attempts"
    end
  end

  # Returns true if +key+ is probably in the filter, false if it definitely is not.
  # Never returns false for a key the filter was built with.
  #
  # Complexity: O(1)
  def contains?(key)
    return false if @fingerprints.empty?

    hash = mix64(@hash_fn.call(key, @seed).to_i & MASK64)
    p0, p1, p2 = positions(hash)
    fingerprint(hash) == (@fingerprints[p0] ^ @fingerprints[p1] ^ @fingerprints[p2])
  end
  alias_method :include?, :contains?
  alias_method :member?, :contains?

  # Returns true if the filter was built from zero keys.
  def empty?
    @size.zero?
  end

  # Serializes the filter to a deterministic String. The same keys, hash function and
  # random source always produce the same bytes. The hash function is not part of the
  # payload and must be supplied again to XorFilter.load.
  def dump
    Marshal.dump([MAGIC, VERSION, @seed, @size, @block_length, @fingerprints.pack("C*")])
  end

  # Restores a filter previously written with #dump. +hash_fn+ must be the same
  # function that was used at build time.
  def self.load(blob, hash_fn:)
    magic, version, seed, size, block_length, packed = Marshal.load(blob)
    unless magic == MAGIC && version == VERSION
      raise ArgumentError, "not a serialized Containers::XorFilter"
    end

    filter = allocate
    filter.instance_eval do
      @hash_fn = hash_fn
      @seed = seed
      @size = size
      @block_length = block_length
      @fingerprints = packed.unpack("C*")
      @attempts = 1
    end
    filter
  end

  def ==(other)
    other.is_a?(Containers::XorFilter) &&
      @seed == other.seed &&
      @size == other.size &&
      @fingerprints == other.instance_variable_get(:@fingerprints)
  end

  private

  # Tries to peel the 3-regular hypergraph induced by +hashes+. Returns the fingerprint
  # table on success, or nil if the graph has a non-empty 2-core (a cycle) and this
  # seed must be abandoned.
  def try_build(hashes)
    capacity = @block_length * 3
    counts = Array.new(capacity, 0)
    xors = Array.new(capacity, 0)

    hashes.each do |hash|
      mixed = mix64(hash)
      positions(mixed).each do |position|
        counts[position] += 1
        xors[position] ^= mixed
      end
    end

    queue = []
    capacity.times { |i| queue << i if counts[i] == 1 }
    stack = []

    until queue.empty?
      position = queue.pop
      next unless counts[position] == 1

      mixed = xors[position]
      stack << [mixed, position]
      positions(mixed).each do |p|
        counts[p] -= 1
        xors[p] ^= mixed
        queue << p if counts[p] == 1
      end
    end

    return nil unless stack.length == hashes.length

    fingerprints = Array.new(capacity, 0)
    stack.reverse_each do |mixed, position|
      p0, p1, p2 = positions(mixed)
      fingerprints[position] = fingerprint(mixed) ^ fingerprints[p0] ^ fingerprints[p1] ^ fingerprints[p2]
    end
    fingerprints
  end

  def positions(mixed)
    length = @block_length
    [
      reduce(mixed, length),
      length + reduce(rotl64(mixed, 21), length),
      2 * length + reduce(rotl64(mixed, 42), length)
    ]
  end

  # Multiply-shift reduction (Lemire): maps a 64-bit value uniformly to 0...n-1.
  # Plain modulo must not be used here: rotation mod 2**64 is multiplication
  # mod (2**64 - 1), so values derived via rotl64 stay correlated under %.
  def reduce(value, n)
    (value * n) >> 64
  end

  def fingerprint(mixed)
    (mixed >> 32) & FINGERPRINT_MASK
  end

  # splitmix64 finalizer; spreads entropy so caller hashes need not be strong.
  def mix64(value)
    value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
    value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & MASK64
    value ^ (value >> 31)
  end

  def rotl64(value, shift)
    ((value << shift) | (value >> (64 - shift))) & MASK64
  end
end
