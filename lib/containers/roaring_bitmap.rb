=begin rdoc
    A compressed bitmap for unsigned 32-bit integers, similar in spirit to a
    Roaring Bitmap. The key space is split into 65536 buckets (the high 16 bits
    of each id). Every bucket is stored in one of three representations that is
    chosen automatically from the data it holds:

    * Array container  - a sorted list of at most 4096 distinct 16-bit values
    * Bitmap container - a 1024-word (8192 byte) bitset for dense buckets
    * Run container    - a list of [start, length] runs for clustered buckets

    The representation is an implementation detail: callers only interact with
    Containers::RoaringBitmap. The container type is re-evaluated after every
    mutation and set operation, so equality, iteration order and serialized
    output never depend on insertion order.
=end
require "stringio"

class Containers::RoaringBitmap
  include Enumerable

  # Raised when serialized input is truncated, corrupt or uses an unknown version.
  class SerializationError < StandardError; end

  MAX_ID         = 0xFFFF_FFFF
  BUCKET_SIZE    = 1 << 16
  BUCKET_MASK    = BUCKET_SIZE - 1
  ARRAY_MAX_CARD = 4096
  BITMAP_WORDS   = 1024
  BITMAP_BYTES   = BITMAP_WORDS * 8

  SERIAL_MAGIC   = "RBMP".b.freeze
  SERIAL_VERSION = 1
  TAG_ARRAY      = 0
  TAG_BITMAP     = 1
  TAG_RUN        = 2

  # @private Brian Kernighan bit counting (Ruby 4.0 has no Integer#bit_count).
  module Popcount
    def self.count(word)
      bits = 0
      until word.zero?
        word &= word - 1
        bits += 1
      end
      bits
    end
  end

  # @private Abstract base class for the three per-bucket representations.
  class Container
    def cardinality
      raise NotImplementedError
    end
    alias_method :size, :cardinality

    def include?(_low)
      raise NotImplementedError
    end
    alias_method :member?, :include?

    # Mutating add; may return a different container object after a type change.
    def add!(_low)
      raise NotImplementedError
    end

    # Mutating delete; may return a different container object after a type change.
    def delete!(_low)
      raise NotImplementedError
    end

    def each(&_block)
      raise NotImplementedError
    end

    def to_a
      values = []
      each { |low| values << low }
      values
    end

    def to_array_container
      raise NotImplementedError
    end

    def to_bitmap_container
      raise NotImplementedError
    end

    def to_run_container
      raise NotImplementedError
    end

    # Number of maximal runs contained in this bucket.
    def run_count
      raise NotImplementedError
    end

    # Serialized payload size in bytes; used to pick the canonical representation.
    def serialized_size
      raise NotImplementedError
    end

    def eql_container?(other)
      to_a == other.to_a
    end

    def ==(other)
      other.is_a?(Container) && eql_container?(other)
    end
    alias_method :eql?, :==

    # Returns the representation-minimal container holding exactly these values.
    def canonical
      run_form = to_run_container
      if cardinality <= ARRAY_MAX_CARD
        array_form = to_array_container
        run_form.serialized_size < array_form.serialized_size ? run_form : array_form
      else
        bitmap_form = to_bitmap_container
        run_form.serialized_size < bitmap_form.serialized_size ? run_form : bitmap_form
      end
    end

    # Set operations return a fresh, canonical container.
    def union_with(other)
      case other
      when ArrayContainer  then union_with_array(other)
      when BitmapContainer then to_bitmap_container.union_with_bitmap(other).canonical
      when RunContainer    then to_bitmap_container.union_with_run(other).canonical
      end
    end

    def intersection_with(other)
      case other
      when ArrayContainer  then intersection_with_array(other)
      when BitmapContainer then to_bitmap_container.intersection_with_bitmap(other).canonical
      when RunContainer    then to_bitmap_container.intersection_with_run(other).canonical
      end
    end

    def difference_with(other)
      case other
      when ArrayContainer  then difference_with_array(other)
      when BitmapContainer then to_bitmap_container.difference_with_bitmap(other).canonical
      when RunContainer    then to_bitmap_container.difference_with_run(other).canonical
      end
    end

    def serialize_body
      raise NotImplementedError
    end

    def self.read_tag_body(io, tag)
      case tag
      when TAG_ARRAY  then ArrayContainer.read_body(io)
      when TAG_BITMAP then BitmapContainer.read_body(io)
      when TAG_RUN    then RunContainer.read_body(io)
      else raise SerializationError, "unknown container type tag: #{tag}"
      end
    end
  end

  # @private Sorted, unique array of 16-bit values; holds at most 4096 values.
  class ArrayContainer < Container
    attr_reader :values

    # Caller guarantees +values+ is sorted and unique.
    def initialize(values = [])
      @values = values
    end

    def cardinality
      @values.size
    end

    def include?(low)
      index = @values.bsearch_index { |value| value >= low }
      !index.nil? && @values[index] == low
    end

    def add!(low)
      index = @values.bsearch_index { |value| value >= low }
      return self if index && @values[index] == low
      if @values.size < ARRAY_MAX_CARD
        index ? @values.insert(index, low) : @values << low
        self
      else
        to_bitmap_container.tap { |bitmap| bitmap.raw_add(low) }.canonical
      end
    end

    def delete!(low)
      index = @values.bsearch_index { |value| value >= low }
      @values.delete_at(index) if index && @values[index] == low
      self
    end

    def each(&block)
      return to_enum(:each) unless block_given?
      @values.each(&block)
      self
    end

    def to_a
      @values.dup
    end

    def to_array_container
      self
    end

    def to_bitmap_container
      words = Array.new(BITMAP_WORDS, 0)
      @values.each { |low| words[low >> 6] |= 1 << (low & 63) }
      BitmapContainer.new(words)
    end

    def to_run_container
      runs = []
      @values.each do |low|
        if runs.any? && runs.last[0] + runs.last[1] == low
          runs.last[1] += 1
        else
          runs << [low, 1]
        end
      end
      RunContainer.new(runs)
    end

    def run_count
      count = 0
      previous = nil
      @values.each do |low|
        count += 1 unless previous && previous + 1 == low
        previous = low
      end
      count
    end

    def serialized_size
      2 + @values.size * 2
    end

    def eql_container?(other)
      other.is_a?(ArrayContainer) ? @values == other.values : super
    end

    def union_with_array(other)
      merged = sorted_union(@values, other.values)
      ArrayContainer.new(merged).canonical
    end

    def intersection_with_array(other)
      scan, probe = cardinality <= other.cardinality ? [@values, other] : [other.values, self]
      ArrayContainer.new(scan.select { |low| probe.include?(low) })
    end

    def difference_with_array(other)
      if cardinality >= other.cardinality
        ArrayContainer.new(@values.reject { |low| other.include?(low) })
      else
        to_bitmap_container.difference_with_bitmap(other.to_bitmap_container).canonical
      end
    end

    def union_with_run(other)
      to_bitmap_container.union_with_run(other).canonical
    end

    def intersection_with_run(other)
      ArrayContainer.new(@values.select { |low| other.include?(low) })
    end

    def difference_with_run(other)
      ArrayContainer.new(@values.reject { |low| other.include?(low) })
    end

    def serialize_body
      [@values.size].pack("n") << @values.pack("n*")
    end

    def self.read_body(io)
      count = Containers::RoaringBitmap.read_exact(io, 2).unpack1("n")
      raise SerializationError, "array container exceeds #{ARRAY_MAX_CARD} values" if count > ARRAY_MAX_CARD
      values = Containers::RoaringBitmap.read_exact(io, count * 2).unpack("n*")
      values.each_cons(2) do |first, second|
        raise SerializationError, "array container values must be strictly sorted" if first >= second
      end
      new(values)
    end

    private

    # Linear merge of two sorted, unique value lists into a sorted, unique list.
    def sorted_union(left, right)
      merged = []
      i = 0
      j = 0
      while i < left.size && j < right.size
        if left[i] < right[j]
          merged << left[i]
          i += 1
        elsif left[i] > right[j]
          merged << right[j]
          j += 1
        else
          merged << left[i]
          i += 1
          j += 1
        end
      end
      merged.concat(left[i..]) if i < left.size
      merged.concat(right[j..]) if j < right.size
      merged
    end
  end

  # @private 8192-byte bitset covering all 65536 values of one bucket.
  class BitmapContainer < Container
    attr_reader :words

    def initialize(words = nil)
      @words = words || Array.new(BITMAP_WORDS, 0)
      @cardinality = nil
    end

    def cardinality
      @cardinality ||= @words.sum { |word| Popcount.count(word) }
    end

    def include?(low)
      (@words[low >> 6] >> (low & 63)) & 1 == 1
    end

    def add!(low)
      @words[low >> 6] |= 1 << (low & 63)
      @cardinality = nil
      cardinality > ARRAY_MAX_CARD ? self : to_array_container
    end

    def delete!(low)
      @words[low >> 6] &= ~(1 << (low & 63))
      @cardinality = nil
      cardinality > ARRAY_MAX_CARD ? self : to_array_container
    end

    def each
      return to_enum(:each) unless block_given?
      @words.each_with_index do |word, word_index|
        until word.zero?
          bit = word & -word
          yield word_index * 64 + bit.bit_length - 1
          word ^= bit
        end
      end
      self
    end

    def to_array_container
      ArrayContainer.new(to_a)
    end

    def to_bitmap_container
      self
    end

    def to_run_container
      runs = []
      each do |low|
        if runs.any? && runs.last[0] + runs.last[1] == low
          runs.last[1] += 1
        else
          runs << [low, 1]
        end
      end
      RunContainer.new(runs)
    end

    def run_count
      count = 0
      previous_last_bit = false
      @words.each do |word|
        unless word.zero?
          starts = Popcount.count(word & ~(word >> 1))
          starts -= 1 if previous_last_bit && (word & 1) == 1
          count += starts
          previous_last_bit = (word >> 63) == 1
        end
      end
      count
    end

    def serialized_size
      BITMAP_BYTES
    end

    def eql_container?(other)
      other.is_a?(BitmapContainer) ? @words == other.words : super
    end

    # Raw bitwise operations shared with run containers.
    def bit_or(other_words)
      merged = Array.new(BITMAP_WORDS) { |i| @words[i] | other_words[i] }
      BitmapContainer.new(merged)
    end

    def bit_and(other_words)
      merged = Array.new(BITMAP_WORDS) { |i| @words[i] & other_words[i] }
      BitmapContainer.new(merged)
    end

    def bit_and_not(other_words)
      merged = Array.new(BITMAP_WORDS) { |i| @words[i] & ~other_words[i] }
      BitmapContainer.new(merged)
    end

    def union_with_array(other)
      result = to_bitmap_container
      other.values.each { |low| result.raw_add(low) }
      result.canonical
    end

    def intersection_with_array(other)
      ArrayContainer.new(other.values.select { |low| include?(low) })
    end

    def difference_with_array(other)
      result = BitmapContainer.new(@words.dup)
      other.values.each { |low| result.raw_delete(low) }
      result.canonical
    end

    def union_with_bitmap(other)
      bit_or(other.words)
    end

    def intersection_with_bitmap(other)
      bit_and(other.words)
    end

    def difference_with_bitmap(other)
      bit_and_not(other.words)
    end

    def union_with_run(other)
      bit_or(other.to_bitmap_words)
    end

    def intersection_with_run(other)
      bit_and(other.to_bitmap_words)
    end

    def difference_with_run(other)
      bit_and_not(other.to_bitmap_words)
    end

    def raw_add(low)
      @words[low >> 6] |= 1 << (low & 63)
      @cardinality = nil
    end

    def raw_delete(low)
      @words[low >> 6] &= ~(1 << (low & 63))
      @cardinality = nil
    end

    def serialize_body
      @words.pack("Q>*")
    end

    def self.read_body(io)
      body = Containers::RoaringBitmap.read_exact(io, BITMAP_BYTES)
      words = body.unpack("Q>*")
      raise SerializationError, "bitmap container must contain more than #{ARRAY_MAX_CARD} values" \
        if words.sum { |word| Popcount.count(word) } <= ARRAY_MAX_CARD
      new(words)
    end

    private
  end

  # @private A list of disjoint, sorted [start, length] runs inside one bucket.
  class RunContainer < Container
    # Array of two-element [start, length] pairs; callers guarantee validity.
    attr_reader :runs

    def initialize(runs = [])
      @runs = runs
    end

    def cardinality
      @runs.sum { |_start, length| length }
    end

    def include?(low)
      index = @runs.bsearch_index { |start, _length| start > low }
      candidate = index.nil? ? @runs.last : (@runs[index - 1] if index > 0)
      return false unless candidate
      start, length = candidate
      low >= start && low < start + length
    end

    def add!(low)
      index = @runs.bsearch_index { |start, _length| start >= low }
      previous_index = index ? index - 1 : @runs.size - 1

      if previous_index >= 0
        prev_start, prev_length = @runs[previous_index]
        return self if low < prev_start + prev_length
      end

      next_index = index || @runs.size
      touches_previous = previous_index >= 0 &&
        @runs[previous_index][0] + @runs[previous_index][1] == low
      touches_next = next_index < @runs.size && @runs[next_index][0] == low + 1

      if touches_previous && touches_next
        prev_start, prev_length = @runs[previous_index]
        _next_start, next_length = @runs[next_index]
        @runs[previous_index] = [prev_start, prev_length + 1 + next_length]
        @runs.delete_at(next_index)
      elsif touches_previous
        @runs[previous_index][1] += 1
      elsif touches_next
        @runs[next_index][0] -= 1
        @runs[next_index][1] += 1
      else
        @runs.insert(next_index, [low, 1])
      end
      self
    end

    def delete!(low)
      index = @runs.bsearch_index { |start, _length| start > low }
      target_index = index ? index - 1 : @runs.size - 1
      return self if target_index < 0
      start, length = @runs[target_index]
      return self if low < start || low >= start + length
      replacement = []
      replacement << [start, low - start] if low > start
      replacement << [low + 1, start + length - low - 1] if low < start + length - 1
      @runs[target_index, 1] = replacement
      self
    end

    def each
      return to_enum(:each) unless block_given?
      @runs.each do |start, length|
        (start...(start + length)).each { |low| yield low }
      end
      self
    end

    def to_array_container
      ArrayContainer.new(to_a)
    end

    def to_bitmap_container
      BitmapContainer.new(to_bitmap_words)
    end

    def to_bitmap_words
      words = Array.new(BITMAP_WORDS, 0)
      @runs.each do |start, length|
        finish = start + length - 1
        first_word = start >> 6
        last_word = finish >> 6
        if first_word == last_word
          words[first_word] |= ((1 << length) - 1) << (start & 63)
        else
          words[first_word] |= (~0 << (start & 63)) & ((1 << 64) - 1)
          (first_word + 1...last_word).each { |i| words[i] = (1 << 64) - 1 }
          words[last_word] |= (1 << ((finish & 63) + 1)) - 1
        end
      end
      words
    end

    def to_run_container
      self
    end

    def run_count
      @runs.size
    end

    def serialized_size
      2 + @runs.size * 4
    end

    def eql_container?(other)
      other.is_a?(RunContainer) ? @runs == other.runs : super
    end

    def union_with_array(other)
      other.union_with_run(self)
    end

    def intersection_with_array(other)
      other.intersection_with_run(self)
    end

    def difference_with_array(other)
      words = to_bitmap_words
      other.values.each { |low| words[low >> 6] &= ~(1 << (low & 63)) }
      BitmapContainer.new(words).canonical
    end

    def union_with_run(other)
      to_bitmap_container.union_with_run(other).canonical
    end

    def intersection_with_run(other)
      to_bitmap_container.intersection_with_run(other).canonical
    end

    def difference_with_run(other)
      to_bitmap_container.difference_with_run(other).canonical
    end

    def serialize_body
      body = [@runs.size].pack("n")
      @runs.each { |start, length| body << [start, length - 1].pack("nn") }
      body
    end

    def self.read_body(io)
      count = Containers::RoaringBitmap.read_exact(io, 2).unpack1("n")
      runs = []
      count.times do
        start, length_minus_one = Containers::RoaringBitmap.read_exact(io, 4).unpack("nn")
        length = length_minus_one + 1
        raise SerializationError, "run exceeds bucket boundary" if start + length > BUCKET_SIZE
        runs << [start, length]
      end
      runs.each_cons(2) do |first, second|
        if first[0] + first[1] > second[0]
          raise SerializationError, "run containers must be disjoint and sorted"
        end
      end
      new(runs)
    end
  end

  # Create a new bitmap. Accepts individual ids or any enumerable of ids:
  #
  #   bitmap = Containers::RoaringBitmap.new(1, 2, 3)
  #   other  = Containers::RoaringBitmap.new([100, 200, 300])
  def initialize(*ids)
    @buckets = {}
    ids.each do |argument|
      if argument.is_a?(Enumerable)
        argument.each { |id| add(id) }
      else
        add(argument)
      end
    end
  end

  # Add an unsigned 32-bit integer id. Returns the bitmap itself so calls can
  # be chained. Raises ArgumentError for ids outside the 32-bit unsigned range.
  #
  #   bitmap = Containers::RoaringBitmap.new
  #   bitmap.add(42) #=> #<Containers::RoaringBitmap ...>
  def add(id)
    id = validate_id(id)
    high = id >> 16
    low  = id & BUCKET_MASK
    bucket = @buckets[high] || ArrayContainer.new
    @buckets[high] = bucket.add!(low)
    self
  end
  alias_method :<<, :add

  # Remove an id if present. Returns the bitmap itself. Out-of-range ids raise.
  def delete(id)
    id = validate_id(id)
    high = id >> 16
    low  = id & BUCKET_MASK
    bucket = @buckets[high]
    if bucket
      @buckets[high] = bucket.delete!(low)
      @buckets.delete(high) if @buckets[high].cardinality.zero?
    end
    self
  end

  # Returns true if the id is set.
  def include?(id)
    return false unless id.is_a?(Integer) && id >= 0 && id <= MAX_ID
    bucket = @buckets[id >> 16]
    !bucket.nil? && bucket.include?(id & BUCKET_MASK)
  end
  alias_method :member?, :include?

  # Iterates over every set id in ascending order.
  def each
    return to_enum(:each) unless block_given?
    @buckets.keys.sort.each do |high|
      @buckets[high].each { |low| yield (high << 16) | low }
    end
    self
  end

  # Number of set ids.
  def cardinality
    @buckets.each_value.sum { |bucket| bucket.cardinality }
  end
  alias_method :size, :cardinality
  alias_method :length, :cardinality

  def empty?
    @buckets.empty?
  end

  def min
    high = @buckets.keys.min
    return nil unless high
    low = @buckets[high].to_a.first
    (high << 16) | low
  end

  def max
    high = @buckets.keys.max
    return nil unless high
    low = @buckets[high].to_a.last
    (high << 16) | low
  end

  # Removes every id.
  def clear
    @buckets.clear
    self
  end

  def initialize_copy(_source)
    @buckets = {}
  end

  # Deep copy.
  def dup
    copy = super
    copy.send(:instance_variable_set, :@buckets, deep_dup_buckets)
    copy
  end

  def ==(other)
    other.is_a?(Containers::RoaringBitmap) && to_a == other.to_a
  end
  alias_method :eql?, :==

  # Returns a new bitmap containing ids from either bitmap.
  def union(other)
    ensure_bitmap!(other)
    result = Containers::RoaringBitmap.new
    merge_set_operation(result, other) { |bucket, other_bucket| bucket.union_with(other_bucket) }
    result
  end
  alias_method :|, :union
  alias_method :+, :union

  # Returns a new bitmap containing ids present in both bitmaps.
  def intersection(other)
    ensure_bitmap!(other)
    result = Containers::RoaringBitmap.new
    @buckets.each_key do |high|
      other_bucket = other.buckets[high]
      if other_bucket
        merged = @buckets[high].intersection_with(other_bucket)
        result.buckets[high] = merged unless merged.cardinality.zero?
      end
    end
    result
  end
  alias_method :&, :intersection

  # Returns a new bitmap containing ids present here but not in +other+.
  def difference(other)
    ensure_bitmap!(other)
    result = Containers::RoaringBitmap.new
    @buckets.each do |high, bucket|
      other_bucket = other.buckets[high]
      merged = other_bucket ? bucket.difference_with(other_bucket) : deep_dup_container(bucket)
      result.send(:buckets)[high] = merged unless merged.cardinality.zero?
    end
    result
  end
  alias_method :-, :difference

  # Destructive union. Returns self.
  def union!(other)
    ensure_bitmap!(other)
    replace_with!(union(other))
  end
  alias_method :merge!, :union!

  # Destructive intersection. Returns self.
  def intersection!(other)
    ensure_bitmap!(other)
    replace_with!(intersection(other))
  end

  # Destructive difference. Returns self.
  def difference!(other)
    ensure_bitmap!(other)
    replace_with!(difference(other))
  end
  alias_method :subtract!, :difference!

  # Serializes to a version-tagged binary string. The format is independent of
  # insertion order and of the in-memory container types.
  def serialize
    serialize_to(StringIO.new).string
  end
  alias_method :dump, :serialize

  # Writes the serialized bitmap to any IO-like object responding to #write.
  def serialize_to(io)
    canonical_buckets = canonicalized_buckets
    io.binmode if io.respond_to?(:binmode)
    io.write(SERIAL_MAGIC)
    io.write([SERIAL_VERSION, canonical_buckets.size].pack("nn"))
    canonical_buckets.each do |high, bucket|
      tag = bucket.is_a?(ArrayContainer) ? TAG_ARRAY :
            bucket.is_a?(BitmapContainer) ? TAG_BITMAP : TAG_RUN
      body = bucket.serialize_body
      io.write([high, tag, body.bytesize].pack("nCN"))
      io.write(body)
    end
    io
  end

  # Rebuilds a bitmap from serialized data produced by #serialize. Raises
  # SerializationError on truncation, trailing garbage, unknown versions or any
  # other structural corruption.
  def self.deserialize(data)
    deserialize_from(StringIO.new(data.to_s))
  end
  class << self
    alias_method :load, :deserialize
  end

  def self.deserialize_from(io)
    io.binmode if io.respond_to?(:binmode)
    magic = read_exact(io, 4)
    raise SerializationError, "bad magic marker" unless magic == SERIAL_MAGIC
    version, bucket_count = read_exact(io, 4).unpack("nn")
    raise SerializationError, "unsupported serialization version: #{version}" unless version == SERIAL_VERSION
    bitmap = new
    previous_high = nil
    bucket_count.times do
      header = read_exact(io, 7)
      high, tag, body_size = header.unpack("nCN")
      raise SerializationError, "bucket keys must be strictly sorted" if previous_high && high <= previous_high
      body_io = StringIO.new(read_exact(io, body_size))
      bucket = Container.read_tag_body(body_io, tag)
      raise SerializationError, "trailing bytes inside container payload" unless body_io.eof?
      bucket = bucket.canonical
      bitmap.send(:buckets)[high] = bucket unless bucket.cardinality.zero?
      previous_high = high
    end
    extra = begin
      io.read(1)
    rescue StandardError
      nil
    end
    raise SerializationError, "trailing bytes after serialized bitmap" unless extra.nil? || extra.empty?
    bitmap
  end

  # @private
  def self.read_exact(io, length)
    data = io.read(length)
    unless data && data.bytesize == length
      raise SerializationError, "truncated serialized data: expected #{length} bytes"
    end
    data
  end

  protected

  attr_reader :buckets

  private

  def validate_id(id)
    unless id.is_a?(Integer) && id >= 0 && id <= MAX_ID
      raise ArgumentError, "id must be an unsigned 32-bit integer (0..#{MAX_ID})"
    end
    id
  end

  def ensure_bitmap!(other)
    unless other.is_a?(Containers::RoaringBitmap)
      raise ArgumentError, "expected a Containers::RoaringBitmap"
    end
  end

  def merge_set_operation(result, other)
    @buckets.each do |high, bucket|
      other_bucket = other.buckets[high]
      merged = other_bucket ? yield(bucket, other_bucket) : deep_dup_container(bucket)
      result.buckets[high] = merged unless merged.cardinality.zero?
    end
    other.buckets.each do |high, bucket|
      result.buckets[high] ||= deep_dup_container(bucket)
    end
  end

  def replace_with!(other)
    @buckets = other.send(:deep_dup_buckets)
    self
  end

  def canonicalized_buckets
    @buckets.keys.sort.each_with_object({}) do |high, canonical|
      bucket = @buckets[high].canonical
      canonical[high] = bucket unless bucket.cardinality.zero?
    end
  end

  def deep_dup_buckets
    @buckets.each_with_object({}) do |(high, bucket), copy|
      copy[high] = deep_dup_container(bucket)
    end
  end

  def deep_dup_container(bucket)
    case bucket
    when ArrayContainer then ArrayContainer.new(bucket.values.dup)
    when BitmapContainer then BitmapContainer.new(bucket.words.dup)
    when RunContainer then RunContainer.new(bucket.runs.map { |start, length| [start, length] })
    end
  end
end
