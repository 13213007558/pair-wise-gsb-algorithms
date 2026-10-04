=begin rdoc
    A XorFilter provides a compact, immutable membership filter with no false negatives
    and a low probability of false positives. It stores approximately 1.23 bytes per key.

    Keys are converted to 64-bit integers by the caller-supplied hash function, and seed
    values are supplied by the caller-supplied random source. Construction uses a three-block
    xor filter; if a generated hypergraph cannot be completely peeled, another seed is tried.
=end
class Containers::XorFilter
  class ConstructionError < StandardError; end

  MAGIC = "AXF1".freeze
  RANGE = 1 << 64
  MASK = RANGE - 1
  SALT = 0x9e3779b97f4a7c15
  BINARY_ENCODING = Encoding::BINARY

  attr_reader :size, :seed

  # Builds a filter from unique keys.
  #
  # +hash+ must respond to #call and return an integer for every key. +random+ must respond
  # to #rand(2 ** 64), like Random. If graph construction does not fully peel after
  # +max_attempts+ seeds, ConstructionError is raised.
  def initialize(keys, hash:, random:, max_attempts: 32)
    raise ArgumentError, "hash must respond to #call" unless hash.respond_to?(:call)
    raise ArgumentError, "random must respond to #rand" unless random.respond_to?(:rand)
    unless max_attempts.is_a?(Integer) && max_attempts > 0
      raise ArgumentError, "max_attempts must be a positive integer"
    end

    unique_keys = keys.to_a
    seen = {}
    unique_keys.each do |key|
      raise ArgumentError, "keys must be unique" if seen.key?(key)
      seen[key] = true
    end

    @size = unique_keys.length
    if @size.zero?
      publish_state(hash, 0, 0, 0, serialized_binary(0, 0, 0, String.new(encoding: BINARY_ENCODING)))
      return
    end

    key_hashes = unique_keys.map { |key| Integer(hash.call(key)) & MASK }
    block_length = block_length_for(@size)

    max_attempts.times do
      seed = Integer(random.rand(RANGE)) & MASK
      fingerprints = construct(key_hashes, block_length, seed)
      next unless fingerprints

      publish_state(hash, @size, seed, block_length, serialized_binary(@size, seed, block_length, fingerprints))
      return
    end

    raise ConstructionError,
          "xor filter construction failed after #{max_attempts} attempt#{max_attempts == 1 ? "" : "s"}"
  end

  # Returns true if the key may be present and false if it is definitely absent.
  def contains?(key)
    return false if @size.zero?

    key_hash = Integer(@hash_proc.call(key)) & MASK
    first, second, third = slots(key_hash, @seed, @block_length)

    expected = mix64(key_hash ^ @seed ^ SALT) & 0xff
    expected ^= fingerprint_at(first)
    expected ^= fingerprint_at(second)
    expected ^= fingerprint_at(third)
    expected.zero?
  end
  alias_method :include?, :contains?
  alias_method :member?, :contains?
  alias_method :[], :contains?

  # Returns a stable, big-endian binary representation.
  def to_binary
    @binary
  end
  alias_method :dump, :to_binary
  alias_method :serialize, :to_binary

  # Restores a filter from to_binary. The same hash callable used during construction
  # must be supplied.
  def self.from_binary(data, hash:)
    raise ArgumentError, "hash must respond to #call" unless hash.respond_to?(:call)
    data = String(data).dup
    data.force_encoding(BINARY_ENCODING)
    raise ArgumentError, "invalid xor filter data" unless data.bytesize >= 24
    raise ArgumentError, "invalid xor filter data" unless data.byteslice(0, 4) == MAGIC

    size, seed, block_length = data.byteslice(4, 20).unpack("Q>Q>N")
    raise ArgumentError, "invalid xor filter data" unless seed <= MASK
    raise ArgumentError, "invalid xor filter data" unless data.bytesize == 24 + 3 * block_length
    raise ArgumentError, "invalid xor filter data" unless size.zero? == block_length.zero?
    expected_block_length = size.zero? ? 0 : (41 * size + 99) / 100 + 32
    raise ArgumentError, "invalid xor filter data" unless block_length == expected_block_length

    filter = allocate
    filter.send(:publish_state, hash, size, seed, block_length, data)
    filter
  end
  singleton_class.send(:alias_method, :load, :from_binary)
  singleton_class.send(:alias_method, :deserialize, :from_binary)

  private

  def block_length_for(size)
    size.zero? ? 0 : (41 * size + 99) / 100 + 32
  end

  def publish_state(hash_proc, size, seed, block_length, binary)
    @hash_proc = hash_proc
    @size = size
    @seed = seed
    @block_length = block_length
    @binary = binary.freeze
    freeze
  end

  def serialized_binary(size, seed, block_length, fingerprints)
    MAGIC.b + [size, seed, block_length].pack("Q>Q>N") + fingerprints
  end

  def construct(key_hashes, block_length, seed)
    size = key_hashes.length
    slot_count = 3 * block_length
    first_positions = Array.new(size)
    second_positions = Array.new(size)
    third_positions = Array.new(size)
    degrees = Array.new(slot_count, 0)
    heads = Array.new(slot_count, -1)
    next_nodes = Array.new(3 * size, -1)
    removed = Array.new(size, false)

    size.times do |edge|
      key_hash = key_hashes[edge]
      first, second, third = slots(key_hash, seed, block_length)
      first_positions[edge] = first
      second_positions[edge] = second
      third_positions[edge] = third

      [[first, 0], [second, 1], [third, 2]].each do |slot, occurrence|
        node = 3 * edge + occurrence
        next_nodes[node] = heads[slot]
        heads[slot] = node
        degrees[slot] += 1
      end
    end

    queue = []
    degrees.each_with_index { |degree, slot| queue << slot if degree == 1 }
    peel_order = []
    queue_index = 0

    while queue_index < queue.length
      slot = queue[queue_index]
      queue_index += 1
      next unless degrees[slot] == 1

      edge = active_edge(heads, next_nodes, removed, slot)
      next unless edge

      peel_order << [edge, slot]
      removed[edge] = true

      [first_positions[edge], second_positions[edge], third_positions[edge]].each do |position|
        degrees[position] -= 1
        queue << position if degrees[position] == 1
      end
    end

    return unless peel_order.length == size

    fingerprints = "\0".b * slot_count
    peel_order.reverse_each do |edge, chosen_slot|
      positions = [first_positions[edge], second_positions[edge], third_positions[edge]]
      other_positions = positions.reject { |position| position == chosen_slot }
      next unless other_positions.length == 2

      value = mix64(key_hashes[edge] ^ seed ^ SALT) & 0xff
      other_positions.each { |position| value ^= fingerprints.getbyte(position) }
      fingerprints.setbyte(chosen_slot, value)
    end

    return unless key_hashes.all? { |key_hash| matches?(key_hash, fingerprints, block_length, seed) }

    fingerprints
  end

  def active_edge(heads, next_nodes, removed, slot)
    node = heads[slot]
    while node >= 0
      edge = node / 3
      return edge unless removed[edge]
      node = next_nodes[node]
    end
    nil
  end

  def matches?(key_hash, fingerprints, block_length, seed)
    first, second, third = slots(key_hash, seed, block_length)
    value = mix64(key_hash ^ seed ^ SALT) & 0xff
    value ^= fingerprints.getbyte(first)
    value ^= fingerprints.getbyte(second)
    value ^= fingerprints.getbyte(third)
    value.zero?
  end

  def fingerprint_at(index)
    @binary.getbyte(24 + index)
  end

  def mix64(value)
    value &= MASK
    value ^= value >> 30
    value = (value * 0xbf58476d1ce4e5b9) & MASK
    value ^= value >> 27
    value = (value * 0x94d049bb133111eb) & MASK
    value ^ value >> 31
  end

  def slots(key_hash, seed, block_length)
    first = mix64(key_hash ^ seed) % block_length
    second = block_length + mix64(key_hash ^ seed ^ 0x517cc1b727220a95) % block_length
    third = 2 * block_length + mix64(key_hash ^ seed ^ 0x6eed0e9da4d94a4f) % block_length
    [first, second, third]
  end

end
