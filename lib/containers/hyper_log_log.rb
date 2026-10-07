require 'stringio'

class Containers::HyperLogLog
  class Error < StandardError; end

  MIN_PRECISION = 4
  MAX_PRECISION = 16
  DEFAULT_PRECISION = 14
  HASH_ALGORITHM = "MurmurHash3_x86_32".freeze
  HASH_SEED = 0x9747b28c
  INPUT_ENCODING = Encoding::UTF_8
  FORMAT_VERSION = 1

  MAGIC = "AHLL".b.freeze
  MURMUR_C1 = 0xcc9e2d51
  MURMUR_C2 = 0x1b873593
  MURMUR_C3 = 0xe6546b64
  MASK_32 = 0xffffffff

  attr_reader :precision

  # Create a HyperLogLog sketch. Precision controls the number of registers:
  # 2 ** precision. Supported precisions are 4 through 16.
  def initialize(precision = DEFAULT_PRECISION)
    precision = precision.to_int if precision.respond_to?(:to_int)
    unless precision.is_a?(Integer) && precision >= MIN_PRECISION && precision <= MAX_PRECISION
      raise ArgumentError, "precision must be an integer between #{MIN_PRECISION} and #{MAX_PRECISION}"
    end

    init_state(precision)
  end

  # Add one item to the sketch. Strings, symbols, and integers are encoded as
  # fixed UTF-8 tagged bytes before hashing.
  def add(element)
    hashed_value = hash_element(element)
    index = hashed_value >> (32 - @precision)
    rank = leading_rank(hashed_value)
    update_register(index, rank)
    self
  end
  alias_method :<<, :add
  alias_method :push, :add

  # Return a new sketch containing the union of both sketches without changing
  # either sketch.
  def merge(other)
    dup.merge!(other)
  end

  # Fold another compatible sketch into this sketch. A higher-precision sketch
  # may be reduced to this precision, but precision upgrades are rejected.
  def merge!(other)
    merged_registers = registers_from(other)
    merged_registers.each do |index, rank|
      update_register(index, rank)
    end
    self
  end

  # Estimate the number of distinct added items.
  def estimate
    validate!
    zero_count = @register_count - nonzero_count
    return 0 if zero_count == @register_count

    register_sum = 0.0
    each_register do |_index, rank|
      register_sum += 2.0 ** -rank
    end

    estimate = alpha * @register_count * @register_count / register_sum

    if zero_count > 0 && estimate <= 2.5 * @register_count
      @register_count * Math.log(@register_count.to_f / zero_count)
    elsif estimate > (2 ** 32) / 30.0
      -(2 ** 32) * Math.log(1.0 - estimate / (2 ** 32))
    else
      estimate
    end
  end
  alias_method :cardinality, :estimate
  alias_method :count, :estimate
  alias_method :size, :estimate

  def registers
    validate!
    if @dense
      @dense.dup
    else
      Array.new(@register_count) { |index| @sparse.fetch(index, 0) }
    end
  end

  def sparse?
    @dense.nil?
  end

  def hash_algorithm
    HASH_ALGORITHM
  end

  def hash_seed
    HASH_SEED
  end

  def input_encoding
    INPUT_ENCODING
  end

  def dump
    validate!
    header = [
      MAGIC,
      FORMAT_VERSION,
      @precision,
      1,
      HASH_SEED,
      1,
      @dense ? 1 : 0
    ].pack("a4CCCNCC")

    if @dense
      header + @dense.pack("C*")
    else
      entries = @sparse.sort
      payload = "".b
      entries.each do |index, rank|
        payload << [index, rank].pack("nC")
      end
      header + [entries.size].pack("N") + payload
    end
  end
  alias_method :to_binary, :dump

  def save(io)
    raise TypeError, "io must respond to write" unless io.respond_to?(:write)
    io.binmode if io.respond_to?(:binmode)
    io.write(dump)
    self
  end

  def self.load(data)
    if data.respond_to?(:read)
      data.binmode if data.respond_to?(:binmode)
      data = data.read
    end
    raise TypeError, "serialized HyperLogLog must be binary data" unless data.is_a?(String)

    data = data.b
    header_size = 13
    raise Error, "truncated HyperLogLog data" if data.bytesize < header_size

    magic, version, precision, hash_algorithm_id, seed, encoding_id, flags =
      data.byteslice(0, header_size).unpack("a4CCCNCC")
    raise Error, "invalid HyperLogLog magic" unless magic == MAGIC
    raise Error, "unsupported HyperLogLog format version: #{version}" unless version == FORMAT_VERSION
    unless precision >= MIN_PRECISION && precision <= MAX_PRECISION
      raise Error, "invalid HyperLogLog precision: #{precision}"
    end
    raise Error, "unsupported HyperLogLog hash algorithm" unless hash_algorithm_id == 1
    raise Error, "HyperLogLog hash seed does not match" unless seed == HASH_SEED
    raise Error, "unsupported HyperLogLog input encoding" unless encoding_id == 1
    raise Error, "invalid HyperLogLog flags" unless flags == 0 || flags == 1

    sketch = allocate
    sketch.send(:init_state, precision)
    payload = data.byteslice(header_size..) || "".b
    m = sketch.instance_variable_get(:@register_count)
    max_rank = sketch.instance_variable_get(:@max_rank)

    if flags == 1
      raise Error, "corrupt dense HyperLogLog registers" unless payload.bytesize == m
      values = payload.unpack("C*")
      unless values.all? { |rank| rank >= 0 && rank <= max_rank }
        raise Error, "corrupt dense HyperLogLog registers"
      end
      sketch.instance_variable_set(:@dense, values)
      sketch.instance_variable_set(:@sparse, {})
    else
      raise Error, "corrupt sparse HyperLogLog registers" if payload.bytesize < 4
      count = payload.byteslice(0, 4).unpack1("N")
      sparse_limit = sketch.instance_variable_get(:@sparse_limit)
      expected_size = 4 + count * 3
      unless count <= sparse_limit && payload.bytesize == expected_size
        raise Error, "corrupt sparse HyperLogLog registers"
      end

      sparse = {}
      offset = 4
      count.times do
        index, rank = payload.byteslice(offset, 3).unpack("nC")
        unless index >= 0 && index < m && rank >= 1 && rank <= max_rank && !sparse.key?(index)
          raise Error, "corrupt sparse HyperLogLog registers"
        end
        sparse[index] = rank
        offset += 3
      end
      sketch.instance_variable_set(:@sparse, sparse)
      sketch.instance_variable_set(:@dense, nil)
    end

    sketch.send(:validate!)
    sketch
  end
  singleton_class.send(:alias_method, :from_binary, :load)

  def hash_config
    {
      algorithm: hash_algorithm,
      seed: hash_seed,
      input_encoding: input_encoding.name
    }
  end

  def initialize_dup(source)
    super
    @dense = @dense.dup if @dense
    @sparse = @sparse.dup
  end

  private

  def init_state(precision)
    @precision = precision
    @register_count = 1 << precision
    @rank_bits = 32 - precision
    @max_rank = @rank_bits + 1
    @sparse_limit = [256, @register_count / 4].min
    @sparse = {}
    @dense = nil
  end

  def hash_element(element)
    murmur3_32(element_bytes(element), HASH_SEED)
  end

  def element_bytes(element)
    value = case element
            when String then "s:#{element}"
            when Symbol then "y:#{element.name}"
            when Integer then "i:#{element}"
            else raise TypeError, "HyperLogLog elements must be a String, Symbol, or Integer"
            end
    value.encode(INPUT_ENCODING).b
  rescue Encoding::UndefinedConversionError,
         Encoding::InvalidByteSequenceError,
         Encoding::ConverterNotFoundError
    raise ArgumentError, "HyperLogLog elements must be valid UTF-8"
  end

  def leading_rank(hashed_value)
    rank_window = hashed_value & ((1 << @rank_bits) - 1)
    return @max_rank if rank_window.zero?

    rank = 1
    mask = 1
    while (rank_window & mask).zero?
      rank += 1
      mask <<= 1
    end
    rank
  end

  def update_register(index, rank)
    if @dense
      @dense[index] = rank if rank > @dense[index]
    elsif rank > @sparse.fetch(index, 0)
      @sparse[index] = rank
      densify if @sparse.size > @sparse_limit
    end
  end

  def densify
    @dense = Array.new(@register_count, 0)
    @sparse.each do |index, rank|
      @dense[index] = rank
    end
    @sparse = {}
  end

  def registers_from(other)
    unless other.is_a?(Containers::HyperLogLog)
      raise TypeError, "can only merge another HyperLogLog"
    end
    unless hash_config == other.hash_config
      raise ArgumentError, "cannot merge HyperLogLog sketches with different hash configurations"
    end
    unless other.precision >= @precision
      raise ArgumentError, "cannot fold a lower precision HyperLogLog sketch into a higher precision sketch"
    end

    other.send(:validate!)
    validate!

    folded = []
    shift = other.precision - @precision
    other_max_rank = 32 - other.precision + 1
    other.send(:each_nonzero_register) do |index, rank|
      sub_index = index & ((1 << shift) - 1)
      folded_rank = if shift.zero?
                      rank
                    elsif rank == other_max_rank
                      sub_index.zero? ? @max_rank : shift - trailing_zero_bits(sub_index)
                    else
                      rank
                    end
      folded << [index >> shift, folded_rank]
    end
    folded
  end

  def each_register
    if @dense
      @dense.each_with_index { |rank, index| yield(index, rank) }
    else
      @register_count.times { |index| yield(index, @sparse.fetch(index, 0)) }
    end
  end

  def each_nonzero_register
    if @dense
      @dense.each_with_index do |rank, index|
        yield(index, rank) if rank > 0
      end
    else
      @sparse.each_pair do |index, rank|
        yield(index, rank)
      end
    end
  end

  def nonzero_count
    @dense ? @dense.count { |rank| rank > 0 } : @sparse.size
  end

  def trailing_zero_bits(value)
    (value & -value).bit_length - 1
  end

  def alpha
    case @register_count
    when 16 then 0.673
    when 32 then 0.697
    when 64 then 0.709
    else 0.7213 / (1.0 + 1.079 / @register_count)
    end
  end

  def validate!
    if @dense
      unless @dense.is_a?(Array) && @dense.length == @register_count &&
             @dense.all? { |rank| rank.is_a?(Integer) && rank >= 0 && rank <= @max_rank }
        raise Error, "corrupt HyperLogLog registers"
      end
      raise Error, "corrupt HyperLogLog registers" unless @sparse == {}
    else
      unless @sparse.is_a?(Hash) && @sparse.size <= @sparse_limit
        raise Error, "corrupt HyperLogLog registers"
      end
      @sparse.each do |index, rank|
        unless index.is_a?(Integer) && index >= 0 && index < @register_count &&
               rank.is_a?(Integer) && rank >= 1 && rank <= @max_rank
          raise Error, "corrupt HyperLogLog registers"
        end
      end
    end
    true
  end

  def murmur3_32(bytes, seed)
    hash_value = seed
    block_count = bytes.bytesize / 4

    block_count.times do |block_index|
      value = bytes.byteslice(block_index * 4, 4).unpack1("V")
      value = rotate_left_32((value * MURMUR_C1) & MASK_32, 15)
      value = (value * MURMUR_C2) & MASK_32
      hash_value ^= value
      hash_value = rotate_left_32(hash_value, 13)
      hash_value = (hash_value * 5 + MURMUR_C3) & MASK_32
    end

    remainder = bytes.bytesize % 4
    if remainder > 0
      value = 0
      bytes.byteslice(block_count * 4, remainder).each_byte.with_index do |byte, tail_index|
        value |= byte << (tail_index * 8)
      end
      value = rotate_left_32((value * MURMUR_C1) & MASK_32, 15)
      value = (value * MURMUR_C2) & MASK_32
      hash_value ^= value
    end

    hash_value ^= bytes.bytesize
    hash_value ^= hash_value >> 16
    hash_value = (hash_value * 0x85ebca6b) & MASK_32
    hash_value ^= hash_value >> 13
    hash_value = (hash_value * 0xc2b2ae35) & MASK_32
    hash_value ^= hash_value >> 16
    hash_value
  end

  def rotate_left_32(value, positions)
    ((value << positions) | (value >> (32 - positions))) & MASK_32
  end
end
