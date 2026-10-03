=begin rdoc
    A Wavelet Matrix supports rank, select, range frequency, and range order
    statistics on an immutable integer sequence.

    Negative integers are handled by shifting every encoded value by the
    sequence minimum, preserving signed integer order while keeping bit
    vectors unsigned.
=end
class Containers::WaveletMatrix
  WORD_BITS = Integer(1.size * 8).freeze
  private_constant :WORD_BITS

  class BitVector
    attr_reader :size

    def initialize(size)
      @size = size
      @words = Array.new((size + WORD_BITS - 1) / WORD_BITS, 0)
      @prefix_ones = nil
    end

    def []=(position, bit)
      validate_position(position)
      raise ArgumentError, "bit must be 0 or 1" unless bit == 0 || bit == 1

      word, offset = position.divmod(WORD_BITS)
      if bit.zero?
        @words[word] &= ~(1 << offset)
      else
        @words[word] |= (1 << offset)
      end
    end

    def build
      @prefix_ones = Array.new(@words.length + 1, 0)
      @words.each_with_index do |word, index|
        @prefix_ones[index + 1] = @prefix_ones[index] + popcount(word)
      end
      freeze
    end

    def [](position)
      validate_position(position)
      word, offset = position.divmod(WORD_BITS)
      (@words[word] >> offset) & 1
    end

    def rank1(position)
      position = [[position, 0].max, @size].min
      word = position / WORD_BITS
      offset = position % WORD_BITS
      count = @prefix_ones[word]
      return count if offset.zero?

      count + popcount(@words[word] & ((1 << offset) - 1))
    end

    def rank0(position)
      position - rank1(position)
    end

    def select1(k)
      select_bit(1, k)
    end

    def select0(k)
      select_bit(0, k)
    end

    def bitmap_bits
      @size
    end

    def auxiliary_bits
      @prefix_ones.length * WORD_BITS
    end

    def estimated_bytes
      @words.length * Integer(1.size) + @prefix_ones.length * Integer(1.size)
    end

    private

    def validate_position(position)
      return if position.is_a?(Integer) && position >= 0 && position < @size

      raise RangeError, "position #{position.inspect} is outside 0...#{@size}"
    end

    def select_bit(bit, k)
      return nil unless k.is_a?(Integer) && k >= 0
      total = bit == 1 ? rank1(@size) : rank0(@size)
      return nil if k >= total

      low = 0
      high = @words.length - 1

      while low < high
        middle = (low + high) / 2
        count = bit == 1 ? @prefix_ones[middle + 1] : zero_prefix(middle + 1)
        if count < k + 1
          low = middle + 1
        else
          high = middle
        end
      end
      before = bit == 1 ? @prefix_ones[low] : zero_prefix(low)
      word = bit == 1 ? @words[low] : ~@words[low]
      position = bit_position_within_word(word, k - before)
      return nil if position >= @size

      low * WORD_BITS + position
    end

    def zero_prefix(word_index)
      word_index * WORD_BITS - @prefix_ones[word_index]
    end

    def popcount(word)
      count = 0
      word &= (1 << WORD_BITS) - 1
      while word.positive?
        word &= word - 1
        count += 1
      end
      count
    end

    def bit_position_within_word(word, occurrence)
      remaining = occurrence
      word &= (1 << WORD_BITS) - 1

      while word.nonzero?
        lowest = word & -word
        position = lowest.bit_length - 1
        return position if remaining.zero?

        word ^= lowest
        remaining -= 1
      end
      position
    end
  end

  Level = Struct.new(:bit_vector, :zeros)
  private_constant :Level

  # Create an immutable Wavelet Matrix from an array of integers. The input
  # array is copied, so later changes to it do not affect the structure.
  #
  #   wm = Containers::WaveletMatrix.new([-2, 3, -2, 0, 3])
  #   wm.kth_smallest(1, 5, 0) #=> -2
  def initialize(sequence)
    unless sequence.is_a?(Array) && sequence.all? { |value| value.is_a?(Integer) }
      raise ArgumentError, "Wavelet Matrix requires an array of integers"
    end

    values = sequence.dup.freeze
    @size = values.length
    @min = values.min || 0
    shifted = values.map { |value| value - @min }
    @max_shifted = shifted.max || 0
    @width = @max_shifted.bit_length
    @levels = build_levels(shifted)
    freeze
  end

  def size
    @size
  end

  def empty?
    @size.zero?
  end

  # Returns occurrences of value in the half-open prefix 0...index.
  def rank(value, index)
    return 0 unless value.is_a?(Integer) && index.is_a?(Integer)
    return 0 if index.negative? || index > @size

    mapped = value - @min
    return 0 if mapped.negative? || mapped > @max_shifted

    left = 0
    right = index
    @levels.each_with_index do |level, level_index|
      bit_position = @width - 1 - level_index
      bit = (mapped >> bit_position) & 1
      left = next_position(left, level, bit)
      right = next_position(right, level, bit)
    end
    right - left
  end

  # Returns the zero-based position of occurrence k of value, or nil.
  def select(value, k)
    return nil unless value.is_a?(Integer) && k.is_a?(Integer) && k >= 0
    return nil if @size.zero?

    mapped = value - @min
    return nil if mapped.negative? || mapped > @max_shifted
    return nil if k >= rank(value, @size)

    left = 0
    path = []
    @levels.each_with_index do |level, level_index|
      bit_position = @width - 1 - level_index
      bit = (mapped >> bit_position) & 1
      path << [level, bit]
      left = next_position(left, level, bit)
    end

    position = left + k
    return nil if position >= @size

    path.reverse_each do |level, bit|
      position =
        if bit.zero?
          level.bit_vector.select0(position)
        else
          level.bit_vector.select1(position - level.zeros)
        end
      return nil if position.nil?
    end
    position
  end

  # Counts occurrences of one value in left...right.
  def frequency(value, left = 0, right = @size)
    validate_range(left, right)
    rank(value, right) - rank(value, left)
  end
  alias_method :count, :frequency

  # Interval-first form of frequency.
  def range_frequency(left, right, value)
    frequency(value, left, right)
  end
  alias_method :range_freq, :range_frequency

  # Counts values in low_value...high_value within left...right.
  def range_count(low_value, high_value, left = 0, right = @size)
    validate_range(left, right)
    return 0 unless low_value.is_a?(Integer) && high_value.is_a?(Integer)
    return 0 if low_value >= high_value || left == right

    range_less(high_value, left, right) - range_less(low_value, left, right)
  end

  # Returns the zero-based kth smallest value in left...right.
  def kth_smallest(left = 0, right = @size, k = 0)
    validate_range(left, right)
    return nil if left == right
    return kth_order_statistic(left, right, k) if k.is_a?(Integer) && k >= 0 && k < right - left

    raise RangeError, "k #{k.inspect} is outside the interval"
  end

  # Returns the zero-based kth largest value in left...right.
  def kth_largest(left = 0, right = @size, k = 0)
    validate_range(left, right)
    return nil if left == right

    order = right - left - 1 - k
    return kth_order_statistic(left, right, order) if order.is_a?(Integer) && order >= 0 && order < right - left

    raise RangeError, "k #{k.inspect} is outside the interval"
  end

  # Reports packed bitmap and rank auxiliary index space, excluding object overhead.
  def space_usage
    bitmap_bits = @levels.sum { |level| level.bit_vector.bitmap_bits }
    auxiliary_bits = @levels.sum { |level| level.bit_vector.auxiliary_bits + WORD_BITS }

    {
      levels: @levels.length,
      bitmap_bits: bitmap_bits,
      auxiliary_bits: auxiliary_bits,
      total_bits: bitmap_bits + auxiliary_bits,
      estimated_bytes: @levels.sum { |level| level.bit_vector.estimated_bytes + Integer(1.size) }
    }
  end

  private

  def build_levels(shifted)
    current = shifted
    levels = []

    (@width - 1).downto(0) do |bit_position|
      zeros = []
      ones = []
      bit_vector = BitVector.new(@size)
      current.each_with_index do |value, index|
        bit = (value >> bit_position) & 1
        bit_vector[index] = bit
        if bit.zero?
          zeros << value
        else
          ones << value
        end
      end
      bit_vector.build
      levels << Level.new(bit_vector, zeros.length)
      current = zeros.concat(ones)
    end
    levels
  end

  def next_position(position, level, bit)
    if bit.zero?
      level.bit_vector.rank0(position)
    else
      level.zeros + level.bit_vector.rank1(position)
    end
  end

  def validate_range(left, right)
    return if left.is_a?(Integer) && right.is_a?(Integer) &&
              left >= 0 && right <= @size && left <= right

    raise RangeError, "invalid half-open interval #{left.inspect}...#{right.inspect} for size #{@size}"
  end

  def range_less(value, left, right)
    return 0 if left == right
    return right - left if value > @max_shifted + @min
    return 0 if value <= @min

    mapped = value - @min
    count = 0
    @levels.each_with_index do |level, level_index|
      bit = (mapped >> (@width - 1 - level_index)) & 1
      left_zeros = level.bit_vector.rank0(left)
      right_zeros = level.bit_vector.rank0(right)

      if bit.zero?
        left = left_zeros
        right = right_zeros
      else
        count += right_zeros - left_zeros
        left = level.zeros + left - left_zeros
        right = level.zeros + right - right_zeros
      end
    end
    count
  end

  def kth_order_statistic(left, right, k)
    mapped = 0
    @levels.each_with_index do |level, level_index|
      left_zeros = level.bit_vector.rank0(left)
      right_zeros = level.bit_vector.rank0(right)
      zeros = right_zeros - left_zeros

      if k < zeros
        left = left_zeros
        right = right_zeros
      else
        k -= zeros
        mapped |= 1 << (@width - 1 - level_index)
        left = level.zeros + left - left_zeros
        right = level.zeros + right - right_zeros
      end
    end
    mapped + @min
  end
end
