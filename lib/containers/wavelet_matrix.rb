=begin rdoc
    A Wavelet Matrix supports rank, select, range frequency, and range order-statistic
    queries on an immutable integer sequence. Negative integers and duplicate values are
    supported.

    All ranges use half-open indices: +[left, right)+.
=end
class Containers::WaveletMatrix
  class BitVector
    attr_reader :size, :ones

    def initialize(values, bit)
      @size = values.size
      word_count = (@size + 63) / 64
      words = Array.new(word_count, 0)

      values.each_with_index do |value, index|
        words[index / 64] |= 1 << (index % 64) unless (value >> bit).even?
      end

      rank_prefixes = Array.new(word_count + 1, 0)
      ones_before = 0

      word_count.times do |word_index|
        valid_bits = [@size - word_index * 64, 64].min
        valid_mask = (1 << valid_bits) - 1
        word = words[word_index] & valid_mask
        words[word_index] = word

        rank_prefixes[word_index] = ones_before
        word_ones = popcount(word)
        ones_before += word_ones
      end

      @ones = ones_before
      rank_prefixes[word_count] = ones_before

      @words = words.pack("Q*")
      @rank_prefixes = rank_prefixes.pack("Q*")
    end

    def rank_ones(position)
      return 0 if position <= 0
      return @ones if position >= @size
      word_index = position / 64
      offset = position % 64
      ones = read_packed(@rank_prefixes, word_index)
      word = read_packed(@words, word_index)
      ones + popcount(word & ((1 << offset) - 1))
    end

    def rank_zeros(position)
      position - rank_ones(position)
    end

    def select_one(occurrence)
      select_bit(occurrence, true)
    end

    def select_zero(occurrence)
      zeros = @size - @ones
      select_bit(occurrence, false, zeros)
    end

    def space_usage
      {
        bitmap_bytes: @words.bytesize,
        rank_index_bytes: @rank_prefixes.bytesize,
        auxiliary_index_bytes: @rank_prefixes.bytesize,
        total_bytes: @words.bytesize + @rank_prefixes.bytesize,
        bitmap_bits: @size,
        rank_entries: @rank_prefixes.bytesize / 8
      }
    end

    private

    def popcount(word)
      count = 0
      until word.zero?
        word &= word - 1
        count += 1
      end
      count
    end

    def read_packed(bytes, index)
      bytes.byteslice(index * 8, 8).unpack1("Q")
    end

    def select_bit(occurrence, looking_for_ones, zeros = nil)
      total = looking_for_ones ? @ones : zeros
      raise RangeError, "occurrence is out of range" unless occurrence >= 1 && occurrence <= total

      word_count = @words.bytesize / 8
      word_index = (0...word_count).bsearch do |index|
        ones = read_packed(@rank_prefixes, index + 1)
        matched = looking_for_ones ? ones : [@size, (index + 1) * 64].min - ones
        matched >= occurrence
      end

      ones_before = read_packed(@rank_prefixes, word_index)
      matched_before = looking_for_ones ? ones_before : word_index * 64 - ones_before

      loop do
        valid_bits = [@size - word_index * 64, 64].min
        valid_mask = (1 << valid_bits) - 1
        word = read_packed(@words, word_index)
        bits = looking_for_ones ? word & valid_mask : valid_mask ^ (word & valid_mask)
        matched = popcount(bits)
        target = occurrence - matched_before

        if target <= matched
          (target - 1).times { bits &= bits - 1 }
          lowest_bit = bits & -bits
          return word_index * 64 + lowest_bit.bit_length - 1
        end

        matched_before += matched
        word_index += 1
      end
    end
  end

  private_constant :BitVector

  # Creates a wavelet matrix from an enumerable of integers. The input is not modified.
  #
  # Complexity: O(n log sigma), where sigma is the number of bits needed to represent
  # the shifted value range.
  def initialize(values)
    values = values.to_a.dup
    unless values.all?(Integer)
      raise ArgumentError, "WaveletMatrix only supports integer sequences"
    end

    @length = values.length
    @offset = 0
    @bit_width = 0
    @levels = []

    return if empty?

    minimum = values.min
    maximum = values.max
    @offset = -minimum
    shifted = values.map { |value| value + @offset }
    @bit_width = (maximum - minimum).bit_length

    @bit_width.times do |depth|
      bit = @bit_width - depth - 1
      bit_vector = BitVector.new(shifted, bit)
      zeros = []
      ones = []

      shifted.each do |value|
        if ((value >> bit) & 1).zero?
          zeros << value
        else
          ones << value
        end
      end

      @levels << [bit_vector, zeros.length]
      shifted = zeros + ones
    end
  end

  # Returns the number of integers in the sequence.
  attr_reader :length
  alias_method :size, :length

  # Returns true when the sequence contains no integers.
  def empty?
    @length.zero?
  end

  # Returns the number of occurrences of +value+ in +[0, position)+, or in +[left, right)+
  # when both bounds are supplied.
  #
  # Complexity: O(log sigma)
  def rank(value, left, right = nil)
    return 0 unless value.is_a?(Integer)
    if right.nil?
      right = left
      left = 0
    end
    left, right = normalize_bounds(left, right)
    code = shifted_code(value)
    return 0 if code.nil?

    @levels.each_with_index do |(bit_vector, _), depth|
      bit = @bit_width - depth - 1
      left_ones = bit_vector.rank_ones(left)
      right_ones = bit_vector.rank_ones(right)

      if ((code >> bit) & 1).zero?
        left -= left_ones
        right -= right_ones
      else
        zero_count = @levels[depth][1]
        left = zero_count + left_ones
        right = zero_count + right_ones
      end
    end

    right - left
  end

  # Returns the index of the +occurrence+-th occurrence of +value+, counting from 1.
  #
  # Complexity: O(log sigma log n)
  def select(value, occurrence)
    raise ArgumentError, "value must be an integer" unless value.is_a?(Integer)
    raise ArgumentError, "occurrence must be a positive integer" unless occurrence.is_a?(Integer) && occurrence.positive?
    code = shifted_code(value)
    raise RangeError, "occurrence is out of range" if code.nil?

    left = 0
    right = @length

    @levels.each_with_index do |(bit_vector, zero_count), depth|
      bit = @bit_width - depth - 1
      left_ones = bit_vector.rank_ones(left)
      right_ones = bit_vector.rank_ones(right)

      if ((code >> bit) & 1).zero?
        left -= left_ones
        right -= right_ones
      else
        left = zero_count + left_ones
        right = zero_count + right_ones
      end
    end

    count = right - left
    raise RangeError, "occurrence is out of range" unless occurrence <= count

    position = left + occurrence - 1
    @levels.each_with_index.to_a.reverse_each do |(bit_vector, zero_count), depth|
      bit = @bit_width - depth - 1
      if ((code >> bit) & 1).zero?
        position = bit_vector.select_zero(position + 1)
      else
        position = bit_vector.select_one(position - zero_count + 1)
      end
    end
    position
  end

  # Returns the number of occurrences of +value+ in the half-open range +[left, right)+.
  #
  # Complexity: O(log sigma)
  def frequency(value, left, right = @length)
    rank(value, left, right)
  end
  alias_method :range_frequency, :frequency

  # Returns the +k+-th smallest integer in +[left, right)+, where +k+ is zero-based.
  #
  # Complexity: O(log sigma)
  def kth_smallest(left, right, k)
    left, right = normalize_bounds(left, right)
    k = validate_non_negative_integer(k, "k")
    width = right - left
    raise RangeError, "k is out of range" unless k < width

    code = 0
    @levels.each_with_index do |(bit_vector, zero_count), depth|
      left_zeros = left - bit_vector.rank_ones(left)
      right_zeros = right - bit_vector.rank_ones(right)
      zeros = right_zeros - left_zeros

      if k < zeros
        left = left_zeros
        right = right_zeros
      else
        k -= zeros
        bit = @bit_width - depth - 1
        code |= 1 << bit
        left = zero_count + bit_vector.rank_ones(left)
        right = zero_count + bit_vector.rank_ones(right)
      end
    end

    code - @offset
  end

  # Reports bitmap storage, packed rank index storage, and per-level boundary storage.
  # Select reuses the rank index. Ruby object overhead is not included.
  def space_usage
    level_usage = @levels.map { |bit_vector, _| bit_vector.space_usage }
    bitmap_bytes = level_usage.sum(0) { |usage| usage[:bitmap_bytes] }
    rank_index_bytes = level_usage.sum(0) { |usage| usage[:rank_index_bytes] }
    boundary_index_bytes = @levels.length * 8
    auxiliary_index_bytes = rank_index_bytes + boundary_index_bytes

    {
      length: @length,
      levels: @levels.length,
      bitmap_bits: @length * @bit_width,
      bitmap_bytes: bitmap_bytes,
      rank_index_bytes: rank_index_bytes,
      select_index_bytes: 0,
      boundary_index_bytes: boundary_index_bytes,
      auxiliary_index_bytes: auxiliary_index_bytes,
      total_bytes: bitmap_bytes + auxiliary_index_bytes,
      bit_vectors: level_usage
    }
  end

  private

  def normalize_bounds(left, right)
    left = validate_non_negative_integer(left, "left")
    right = validate_non_negative_integer(right, "right")
    raise RangeError, "right must not be greater than length" if right > @length
    raise ArgumentError, "left must not be greater than right" if left > right
    [left, right]
  end

  def validate_non_negative_integer(value, name)
    raise ArgumentError, "#{name} must be a non-negative integer" unless value.is_a?(Integer) && value >= 0
    value
  end

  def shifted_code(value)
    code = value + @offset
    return if code < 0 || code >= 1 << @bit_width
    code
  end
end
