# frozen_string_literal: true

require 'json'

=begin rdoc
    HyperLogLog estimates the number of distinct values in a stream without retaining
    every value. This implementation uses 64-bit XXH64 hashes, UTF-8 input encoding,
    a sparse representation for small sketches, and a versioned serialization format.
=end
class Containers::HyperLogLog
  FORMAT_VERSION = 1
  MIN_PRECISION = 4
  MAX_PRECISION = 18
  DEFAULT_PRECISION = 12
  SPARSE_LIMIT = 1024

  HASH_ALGORITHM = "XXH64"
  HASH_SEED = 0
  HASH_ENCODING = "UTF-8"

  MASK_64 = (1 << 64) - 1
  PRIME64_1 = 0x9E3779B185EBCA87
  PRIME64_2 = 0xC2B2AE3D27D4EB4F
  PRIME64_3 = 0x165667B19E3779F9
  PRIME64_4 = 0x85EBCA77C2B2AE63
  PRIME64_5 = 0x27D4EB2F165667C5

  # Creates a new HyperLogLog sketch. Precision may be between 4 and 18; higher
  # precision reduces estimation error at the cost of more memory.
  def initialize(precision = DEFAULT_PRECISION)
    precision = precision.to_int
    unless precision.between?(MIN_PRECISION, MAX_PRECISION)
      raise ArgumentError, "precision must be between #{MIN_PRECISION} and #{MAX_PRECISION}"
    end

    @precision = precision
    @registers = {}
    @dense = false
  end

  # Adds one item to the sketch. Strings, symbols, and integers have distinct,
  # deterministic byte representations.
  def add(item)
    apply_hash(hash_bytes(encode_item(item)))
  end
  alias_method :<<, :add

  protected def apply_hash(hash_value)
    register_index = hash_value >> (64 - @precision)
    remaining_bits = ((hash_value << @precision) & MASK_64)
    rank = remaining_bits.zero? ? 65 - @precision : 65 - remaining_bits.bit_length
    update_register(register_index, rank)
    self
  end

  # Returns a new sketch containing all values from either sketch. The result uses
  # the lower precision when sketches have different precision.
  def merge(other)
    dup.merge!(other)
  end
  alias_method :+, :merge

  # Merges another sketch into this one and returns self.
  def merge!(other)
    unless other.is_a?(Containers::HyperLogLog)
      raise ArgumentError, "can only merge another HyperLogLog"
    end
    unless hash_configuration == other.send(:hash_configuration)
      raise ArgumentError, "cannot merge HyperLogLog sketches with different hash configuration"
    end
    unless valid_registers? && other.send(:valid_registers?)
      raise ArgumentError, "cannot merge HyperLogLog sketches with corrupt registers"
    end

    target_precision = [@precision, other.precision].min
    fold!(target_precision)

    other.send(:each_register, target_precision) do |index, rank|
      update_register(index, rank)
    end
    self
  end

  # Returns the estimated number of distinct items. Returns 0 for an empty sketch.
  def estimate
    register_count = 1 << @precision
    sum = 0.0
    zero_count = 0

    register_count.times do |index|
      rank = register_rank(index)
      sum += 2.0 ** -rank
      zero_count += 1 if rank.zero?
    end

    return 0 if zero_count == register_count

    alpha = 0.7213 / (1.0 + 1.079 / register_count)
    estimate = alpha * register_count * register_count / sum

    if estimate <= 2.5 * register_count && zero_count.positive?
      estimate = register_count * Math.log(register_count.to_f / zero_count)
    elsif estimate > (1 << 32) / 30.0
      estimate = -(1 << 32) * Math.log(1.0 - estimate / (1 << 64).to_f)
    end

    estimate
  end
  alias_method :cardinality, :estimate

  def precision
    @precision
  end

  def dense?
    @dense
  end

  def sparse?
    !@dense
  end

  # Returns a copy of all register values, including implicit zero registers.
  def registers
    Array.new(1 << @precision) { |index| register_rank(index) }
  end

  # Serializes the sketch to a versioned JSON string.
  def dump
    JSON.generate(
      "format_version" => FORMAT_VERSION,
      "precision" => @precision,
      "hash" => hash_configuration,
      "representation" => @dense ? "dense" : "sparse",
      "registers" => serialized_registers
    )
  end
  alias_method :to_json, :dump

  # Restores a sketch produced by dump.
  def self.load(data)
    raise ArgumentError, "invalid HyperLogLog data" unless data.is_a?(String)

    begin
      payload = JSON.parse(data)
    rescue JSON::ParserError
      raise ArgumentError, "invalid HyperLogLog data"
    end

    sketch = new(extract_precision(payload))
    sketch.send(:load_payload, payload)
    sketch
  end

  def initialize_copy(other)
    super
    @registers = @registers.dup
  end

  protected

  def hash_configuration
    {
      "algorithm" => HASH_ALGORITHM,
      "seed" => HASH_SEED,
      "encoding" => HASH_ENCODING
    }
  end

  def hash_bytes(bytes)
    length = bytes.bytesize
    offset = 0
    if length >= 32
      v1 = (HASH_SEED + PRIME64_1 + PRIME64_2) & MASK_64
      v2 = (HASH_SEED + PRIME64_2) & MASK_64
      v3 = HASH_SEED
      v4 = (HASH_SEED - PRIME64_1) & MASK_64

      while offset + 32 <= length
        v1 = xxh64_round(v1, bytes.byteslice(offset, 8).unpack1("Q<"))
        v2 = xxh64_round(v2, bytes.byteslice(offset + 8, 8).unpack1("Q<"))
        v3 = xxh64_round(v3, bytes.byteslice(offset + 16, 8).unpack1("Q<"))
        v4 = xxh64_round(v4, bytes.byteslice(offset + 24, 8).unpack1("Q<"))
        offset += 32
      end

      hash64 = (rotate64(v1, 1) + rotate64(v2, 7) + rotate64(v3, 12) + rotate64(v4, 18)) & MASK_64
      [v1, v2, v3, v4].each do |lane|
        hash64 ^= xxh64_round(0, lane)
        hash64 = rotate64(hash64, 27)
        hash64 = (multiply64(hash64, PRIME64_1) + PRIME64_4) & MASK_64
      end
    else
      hash64 = (HASH_SEED + PRIME64_5) & MASK_64
    end

    hash64 = (hash64 + length) & MASK_64
    remaining = length - offset

    if remaining >= 4
      value = bytes.byteslice(offset, 4).unpack1("V")
      hash64 = (hash64 ^ multiply64(value, PRIME64_1)) & MASK_64
      hash64 = rotate64(hash64, 23)
      hash64 = (multiply64(hash64, PRIME64_2) + PRIME64_3) & MASK_64
      offset += 4
    end

    while offset < length
      hash64 = (hash64 ^ multiply64(bytes.getbyte(offset), PRIME64_5)) & MASK_64
      hash64 = rotate64(hash64, 11)
      hash64 = multiply64(hash64, PRIME64_1)
      offset += 1
    end

    xxh64_avalanche(hash64)
  end

  def each_register(target_precision)
    unless target_precision <= @precision
      raise ArgumentError, "cannot increase HyperLogLog precision"
    end

    delta = @precision - target_precision

    if @dense
      @registers.each_byte.with_index do |rank, index|
        yield_folded_register(index, rank, delta) { |folded_index, folded_rank| yield(folded_index, folded_rank) }
      end
    else
      @registers.each do |index, rank|
        yield_folded_register(index, rank, delta) { |folded_index, folded_rank| yield(folded_index, folded_rank) }
      end
    end
  end

  def fold!(target_precision)
    target_precision = target_precision.to_int
    unless target_precision.between?(MIN_PRECISION, @precision)
      raise ArgumentError, "target precision must be between #{MIN_PRECISION} and #{@precision}"
    end
    return self if target_precision == @precision

    folded = {}
    each_register(target_precision) do |index, rank|
      folded[index] = rank if rank > folded.fetch(index, 0)
    end

    @precision = target_precision
    @registers = folded
    @dense = false
    convert_to_dense! if @registers.size >= sparse_threshold
    self
  end

  private

  def encode_item(item)
    case item
    when String
      bytes = "s:".b + item.encode(Encoding::UTF_8).b
    when Symbol
      bytes = "y:".b + item.name.encode(Encoding::UTF_8).b
    when Integer
      bytes = "i:".b + item.to_s(10).b
    else
      raise TypeError, "HyperLogLog accepts String, Symbol, or Integer values"
    end
    bytes
  rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => error
    raise ArgumentError, "item cannot be encoded as #{HASH_ENCODING}: #{error.message}"
  end

  def update_register(index, rank)
    if @dense
      current_rank = @registers.getbyte(index)
      @registers.setbyte(index, rank) if rank > current_rank
    else
      current_rank = @registers.fetch(index, 0)
      @registers[index] = rank if rank > current_rank
      convert_to_dense! if @registers.size >= sparse_threshold
    end
  end

  def register_rank(index)
    @dense ? @registers.getbyte(index) : @registers.fetch(index, 0)
  end

  def valid_registers?
    register_count = 1 << @precision
    maximum_rank = 65 - @precision

    if @dense
      @registers.is_a?(String) &&
        @registers.encoding == Encoding::BINARY &&
        @registers.bytesize == register_count &&
        @registers.bytes.all? { |rank| rank <= maximum_rank }
    else
      @registers.is_a?(Hash) &&
        @registers.size < sparse_threshold &&
        @registers.all? do |index, rank|
          index.is_a?(Integer) && rank.is_a?(Integer) &&
            index.between?(0, register_count - 1) &&
            rank.between?(1, maximum_rank)
        end
    end
  end

  def sparse_threshold
    [1 << @precision, SPARSE_LIMIT].min
  end

  def convert_to_dense!
    dense_registers = String.new("\0".b * (1 << @precision), encoding: Encoding::BINARY)
    @registers.each do |index, rank|
      dense_registers.setbyte(index, rank)
    end
    @registers = dense_registers
    @dense = true
  end

  def serialized_registers
    if @dense
      [@registers].pack("m0")
    else
      @registers.map do |index, rank|
        {"index" => index, "rank" => rank}
      end
    end
  end

  def load_payload(payload)
    raise ArgumentError, "invalid HyperLogLog data" unless payload.is_a?(Hash)
    raise ArgumentError, "unsupported HyperLogLog format version" unless payload["format_version"] == FORMAT_VERSION
    raise ArgumentError, "HyperLogLog hash configuration mismatch" unless payload["hash"] == hash_configuration

    maximum_rank = 65 - @precision
    representation = payload["representation"]
    data = payload["registers"]

    case representation
    when "dense" then load_dense_registers(data, maximum_rank)
    when "sparse" then load_sparse_registers(data, maximum_rank)
    else raise ArgumentError, "invalid HyperLogLog representation"
    end
  end

  def load_dense_registers(data, maximum_rank)
    raise ArgumentError, "invalid HyperLogLog registers" unless data.is_a?(String)
    raise ArgumentError, "invalid HyperLogLog registers" unless data.length % 4 == 0
    raise ArgumentError, "invalid HyperLogLog registers" unless data.match?(/\A[A-Za-z0-9+\/]*={0,2}\z/)

    begin
      bytes = data.to_s.unpack1("m0")
    rescue ArgumentError, TypeError
      raise ArgumentError, "invalid HyperLogLog registers"
    end
    raise ArgumentError, "invalid HyperLogLog registers" unless [bytes].pack("m0") == data

    expected_size = 1 << @precision
    raise ArgumentError, "invalid HyperLogLog registers" unless bytes.bytesize == expected_size
    raise ArgumentError, "invalid HyperLogLog registers" if bytes.bytes.any? { |rank| rank < 1 || rank > maximum_rank }

    @registers = bytes
    @dense = true
  end

  def load_sparse_registers(data, maximum_rank)
    raise ArgumentError, "invalid HyperLogLog registers" unless data.is_a?(Array)

    registers = {}
    data.each do |entry|
      raise ArgumentError, "invalid HyperLogLog registers" unless entry.is_a?(Hash)
      index = entry["index"]
      rank = entry["rank"]
      unless index.is_a?(Integer) && rank.is_a?(Integer) &&
          index.between?(0, (1 << @precision) - 1) &&
          rank.between?(1, maximum_rank)
        raise ArgumentError, "invalid HyperLogLog registers"
      end
      raise ArgumentError, "invalid HyperLogLog registers" if registers.key?(index)
      registers[index] = rank
    end
    raise ArgumentError, "invalid HyperLogLog registers" if registers.size >= sparse_threshold

    @registers = registers
    @dense = false
  end

  def self.extract_precision(payload)
    raise ArgumentError, "invalid HyperLogLog data" unless payload.is_a?(Hash)
    precision = payload["precision"]
    unless precision.is_a?(Integer) && precision.between?(MIN_PRECISION, MAX_PRECISION)
      raise ArgumentError, "invalid HyperLogLog precision"
    end
    precision
  end
  private_class_method :extract_precision

  def yield_folded_register(index, rank, delta)
    return yield(index, rank) if delta.zero?
    return if rank.zero?

    folded_index = index >> delta
    removed_bits = index & ((1 << delta) - 1)
    folded_rank = if removed_bits.zero?
      delta + rank
    else
      delta + 1 - removed_bits.bit_length
    end
    yield(folded_index, folded_rank)
  end

  def multiply64(left, right)
    (left * right) & MASK_64
  end

  def rotate64(value, bits)
    ((value << bits) | (value >> (64 - bits))) & MASK_64
  end

  def xxh64_avalanche(value)
    value ^= value >> 33
    value = multiply64(value, PRIME64_2)
    value ^= value >> 29
    value = multiply64(value, PRIME64_3)
    value ^= value >> 32
    value
  end

  def xxh64_round(acc, input)
    acc = (acc + multiply64(input, PRIME64_2)) & MASK_64
    acc = rotate64(acc, 31)
    multiply64(acc, PRIME64_1)
  end
end
