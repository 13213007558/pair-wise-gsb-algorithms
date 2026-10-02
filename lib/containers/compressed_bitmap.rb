module Algorithms; end unless defined?(Algorithms)
module Containers; end unless defined?(Containers)

class Containers::CompressedBitmap
  include Enumerable

  # A compressed set of 32-bit unsigned integers. Buckets are represented
  # internally as sorted arrays, 16-bit-word bitmaps, or runs, but callers only
  # manipulate the resulting set.

  MAX_ID = 0xFFFFFFFF
  BUCKET_SIZE = 1 << 16
  ARRAY_LIMIT = 4096
  BITMAP_WORD_COUNT = 1024
  FULL_BUCKET_MASK = (1 << BUCKET_SIZE) - 1

  SERIAL_MAGIC = "RBM".freeze
  SERIAL_VERSION = 1
  TAG_ARRAY = 0
  TAG_BITMAP = 1
  TAG_RUNS = 2

  class Bucket # :nodoc: all
    attr_reader :kind

    def initialize(kind, data)
      @kind = kind
      @data = data
      @cardinality =
        case kind
        when :array then data.length
        when :bitmap then self.class.popcount(data)
        when :runs then data.inject(0) { |count, (start, last)| count + last - start + 1 }
        else raise ArgumentError, "unknown bucket kind"
        end
    end

    def self.from_mask(mask)
      mask &= Containers::CompressedBitmap::FULL_BUCKET_MASK
      cardinality = popcount(mask)
      runs = extract_runs(mask)
      run_cost = runs.length * 4

      if cardinality <= Containers::CompressedBitmap::ARRAY_LIMIT
        array_cost = cardinality * 2
        return new(:array, mask_to_values(mask)) if array_cost <= run_cost
      end

      return new(:runs, runs) if run_cost < Containers::CompressedBitmap::BITMAP_WORD_COUNT * 8

      new(:bitmap, mask)
    end

    def self.from_array(values)
      from_mask(values.inject(0) { |mask, value| mask | (1 << value) })
    end

    def self.from_runs(runs)
      mask = runs.inject(0) do |bucket_mask, (start, last)|
        unless start.is_a?(Integer) && last.is_a?(Integer) && start >= 0 && last < BUCKET_SIZE && start <= last
          raise ArgumentError, "invalid compressed bitmap run"
        end
        length = last - start + 1
        bucket_mask | (((1 << length) - 1) << start)
      end
      from_mask(mask)
    end

    def self.array(values)
      new(:array, values.dup)
    end

    def self.bitmap(mask)
      new(:bitmap, mask)
    end

    def self.runs(runs)
      new(:runs, runs.map { |run| run.dup })
    end

    def cardinality
      @cardinality
    end

    def empty?
      @cardinality.zero?
    end

    def include?(value)
      case @kind
      when :array then !array_index(value).nil?
      when :bitmap then (@data & (1 << value)) != 0
      when :runs
        !run_index(value).nil?
      end
    end

    def add(value)
      return self if include?(value)
      if @kind == :array && @data.length < Containers::CompressedBitmap::ARRAY_LIMIT
        inserted = @data.dup
        index = insertion_index(value)
        inserted.insert(index, value)
        return self.class.new(:array, inserted)
      end
      self.class.from_mask(mask | (1 << value))
    end

    def delete(value)
      return self unless include?(value)
      self.class.from_mask(mask & ~(1 << value))
    end

    def union(other)
      self.class.from_mask(mask | other.mask)
    end

    def intersection(other)
      self.class.from_mask(mask & other.mask)
    end

    def difference(other)
      self.class.from_mask(mask & ~other.mask)
    end

    def each
      return enum_for(:each) unless block_given?

      case @kind
      when :array
        @data.each { |value| yield value }
      when :bitmap
        values = @data
        while values != 0
          bit = values & -values
          yield bit.bit_length - 1
          values ^= bit
        end
      when :runs
        @data.each { |start, last| (start..last).each { |value| yield value } }
      end
    end

    def to_a
      each.to_a
    end

    def mask
      case @kind
      when :array then @data.inject(0) { |result, value| result | (1 << value) }
      when :bitmap then @data
      when :runs
        @data.inject(0) do |result, (start, last)|
          length = last - start + 1
          result | (((1 << length) - 1) << start)
        end
      end
    end

    def array_index(value)
      low = 0
      high = @data.length - 1
      while low <= high
        middle = (low + high) / 2
        current = @data[middle]
        if current < value
          low = middle + 1
        elsif current > value
          high = middle - 1
        else
          return middle
        end
      end
      nil
    end

    def insertion_index(value)
      low = 0
      high = @data.length
      while low < high
        middle = (low + high) / 2
        if @data[middle] < value
          low = middle + 1
        else
          high = middle
        end
      end
      low
    end

    def run_index(value)
      low = 0
      high = @data.length - 1
      while low <= high
        middle = (low + high) / 2
        start, last = @data[middle]
        if value < start
          high = middle - 1
        elsif value > last
          low = middle + 1
        else
          return middle
        end
      end
      nil
    end

    def dump
      case @kind
      when :array
        [TAG_ARRAY, @data.length].pack("Cn") + @data.pack("n*")
      when :bitmap
        words = Array.new(BITMAP_WORD_COUNT) do |index|
          (@data >> (index * 16)) & 0xFFFF
        end
        [TAG_BITMAP].pack("C") + words.pack("n*")
      when :runs
        payload = @data.flat_map { |start, last| [start, last - start] }
        [TAG_RUNS, @data.length].pack("Cn") + payload.pack("n*")
      end
    end

    def self.load(cursor, bytes)
      tag = read_exact(cursor, bytes, 1).unpack1("C")

      case tag
      when TAG_ARRAY
        count = read_exact(cursor, bytes, 2).unpack1("n")
        raise ArgumentError, "truncated compressed bitmap" if cursor[:position] + count * 2 > bytes.bytesize
        values = bytes.byteslice(cursor[:position], count * 2).unpack("n*")
        cursor[:position] += count * 2
        validate_sorted_values(values)
        bucket = from_array(values)
        raise ArgumentError, "invalid compressed bitmap bucket" unless bucket.kind == :array
        bucket
      when TAG_BITMAP
        payload = read_exact(cursor, bytes, BITMAP_WORD_COUNT * 2)
        words = payload.unpack("n*")
        bucket_mask = 0
        words.each_with_index { |word, index| bucket_mask |= word << (index * 16) }
        bucket = from_mask(bucket_mask)
        raise ArgumentError, "invalid compressed bitmap bucket" unless bucket.kind == :bitmap
        bucket
      when TAG_RUNS
        count = read_exact(cursor, bytes, 2).unpack1("n")
        payload = read_exact(cursor, bytes, count * 4)
        packed_runs = payload.unpack("n*")
        loaded_runs = []
        previous_last = -1
        packed_runs.each_slice(2) do |start, length_minus_one|
          raise ArgumentError, "invalid compressed bitmap bucket" if length_minus_one.nil?
          last = start + length_minus_one
          raise ArgumentError, "invalid compressed bitmap bucket" if last >= BUCKET_SIZE
          raise ArgumentError, "invalid compressed bitmap bucket" if start <= previous_last
          loaded_runs << [start, last]
          previous_last = last
        end
        bucket = from_runs(loaded_runs)
        raise ArgumentError, "invalid compressed bitmap bucket" unless bucket.kind == :runs
        bucket
      else
        raise ArgumentError, "unknown compressed bitmap bucket type"
      end
    end

    def self.read_exact(cursor, bytes, length)
      position = cursor[:position]
      if position + length > bytes.bytesize
        raise ArgumentError, "truncated compressed bitmap"
      end
      cursor[:position] += length
      bytes.byteslice(position, length)
    end

    def self.validate_sorted_values(values)
      raise ArgumentError, "invalid compressed bitmap bucket" if values.empty?
      values.each_cons(2) do |first, second|
        raise ArgumentError, "invalid compressed bitmap bucket" if first >= second
      end
    end

    def self.extract_runs(bucket_mask)
      runs = []
      offset = 0
      remaining = bucket_mask

      while remaining != 0
        lowest = remaining & -remaining
        gap = lowest.bit_length - 1
        offset += gap
        remaining >>= gap

        run_length = (remaining ^ (remaining + 1)).bit_length - 1
        runs << [offset, offset + run_length - 1]
        offset += run_length
        remaining >>= run_length
      end

      runs
    end

    def self.mask_to_values(bucket_mask)
      values = []
      remaining = bucket_mask
      while remaining != 0
        bit = remaining & -remaining
        values << bit.bit_length - 1
        remaining ^= bit
      end
      values
    end

    def self.popcount(value)
      count = 0
      while value != 0
        value &= value - 1
        count += 1
      end
      count
    end
  end

  def initialize(*ids)
    @buckets = {}
    ids = ids.first if ids.length == 1 && ids.first.respond_to?(:each)
    replace(ids)
  end

  def self.[](*ids)
    ids.length == 1 && ids.first.respond_to?(:each) ? new(ids.first) : new(*ids)
  end

  def add(id)
    validate_id(id)
    high = id >> 16
    low = id & 0xFFFF
    bucket = @buckets[high]
    @buckets[high] = bucket ? bucket.add(low) : Bucket.from_array([low])
    self
  end
  alias_method :<<, :add

  def delete(id)
    validate_id(id)
    high = id >> 16
    low = id & 0xFFFF
    bucket = @buckets[high]
    return false unless bucket && bucket.include?(low)

    updated = bucket.delete(low)
    if updated.empty?
      @buckets.delete(high)
    else
      @buckets[high] = updated
    end
    true
  end

  def add_all(ids)
    unless ids.respond_to?(:each)
      raise ArgumentError, "ids must be enumerable"
    end
    grouped = Hash.new { |hash, key| hash[key] = [] }
    ids.each do |id|
      validate_id(id)
      grouped[id >> 16] << (id & 0xFFFF)
    end

    grouped.each do |high, lows|
      existing = @buckets[high]
      values = existing ? (existing.to_a | lows).sort : lows.uniq.sort
      updated = Bucket.from_array(values)
      @buckets[high] = updated unless updated.empty?
    end
    self
  end

  def include?(id)
    return false unless id.is_a?(Integer) && id >= 0 && id <= MAX_ID
    bucket = @buckets[id >> 16]
    !bucket.nil? && bucket.include?(id & 0xFFFF) ? true : false
  end
  alias_method :member?, :include?

  def cardinality
    @buckets.each_value.inject(0) { |count, bucket| count + bucket.cardinality }
  end
  alias_method :size, :cardinality
  alias_method :length, :cardinality

  def empty?
    @buckets.empty?
  end

  def each
    return enum_for(:each) unless block_given?

    @buckets.keys.sort.each do |high|
      @buckets[high].each { |low| yield (high << 16) | low }
    end
  end

  def to_a
    each.to_a
  end

  def union(other)
    ensure_bitmap(other)
    bitmap = self.class.new
    combine(other, bitmap)
    bitmap
  end
  alias_method :|, :union

  def intersection(other)
    ensure_bitmap(other)
    bitmap = self.class.new
    @buckets.keys.sort.each do |high|
      other_bucket = other.send(:bucket, high)
      next unless other_bucket
      result = @buckets[high].intersection(other_bucket)
      bitmap.send(:set_bucket, high, result) unless result.empty?
    end
    bitmap
  end
  alias_method :&, :intersection

  def difference(other)
    ensure_bitmap(other)
    bitmap = self.class.new
    @buckets.keys.sort.each do |high|
      other_bucket = other.send(:bucket, high)
      result = other_bucket ? @buckets[high].difference(other_bucket) : @buckets[high]
      bitmap.send(:set_bucket, high, result) unless result.empty?
    end
    bitmap
  end
  alias_method :-, :difference

  def ==(other)
    other.is_a?(self.class) && to_a == other.to_a
  end
  alias_method :eql?, :==

  def hash
    to_a.hash
  end

  def dump
    sorted_keys = @buckets.keys.sort
    bytes = [SERIAL_MAGIC, SERIAL_VERSION, sorted_keys.length].pack("a3CN")
    sorted_keys.each do |high|
      bytes << [high].pack("n")
      bytes << @buckets[high].dump
    end
    bytes.force_encoding(Encoding::BINARY)
  end
  alias_method :serialize, :dump

  def self.load(data)
    unless data.is_a?(String)
      raise ArgumentError, "compressed bitmap data must be a String"
    end
    if data.bytesize < 8
      raise ArgumentError, "truncated compressed bitmap"
    end

    magic = data.byteslice(0, 3)
    version = data.getbyte(3)
    bucket_count = data.byteslice(4, 4).unpack1("N")
    raise ArgumentError, "unknown compressed bitmap signature" unless magic == SERIAL_MAGIC
    raise ArgumentError, "unsupported compressed bitmap version" unless version == SERIAL_VERSION
    raise ArgumentError, "invalid compressed bitmap" if bucket_count > BUCKET_SIZE

    bitmap = new
    cursor = { :position => 8 }
    previous_high = -1

    bucket_count.times do
      high = Bucket.read_exact(cursor, data, 2).unpack1("n")
      raise ArgumentError, "invalid compressed bitmap" if high <= previous_high
      loaded_bucket = Bucket.load(cursor, data)
      bitmap.send(:set_bucket, high, loaded_bucket)
      previous_high = high
    end

    unless cursor[:position] == data.bytesize
      raise ArgumentError, "trailing bytes after compressed bitmap"
    end
    bitmap
  end
  class << self
    alias_method :deserialize, :load
  end

  private

  def replace(ids)
    unless ids.respond_to?(:each)
      raise ArgumentError, "ids must be enumerable"
    end
    grouped = Hash.new { |hash, key| hash[key] = [] }
    ids.each do |id|
      validate_id(id)
      grouped[id >> 16] << (id & 0xFFFF)
    end
    grouped.each do |high, lows|
      @buckets[high] = Bucket.from_array(lows.uniq.sort)
    end
    self
  end

  def set_bucket(high, bucket)
    @buckets[high] = bucket unless bucket.empty?
  end

  def bucket(high)
    @buckets[high]
  end

  def buckets
    @buckets
  end

  def combine(other, bitmap)
    (@buckets.keys | other.send(:buckets).keys).sort.each do |high|
      first = @buckets[high]
      second = other.send(:bucket, high)
      result =
        if first && second
          first.union(second)
        else
          first || second
        end
      bitmap.send(:set_bucket, high, result)
    end
  end

  def validate_id(id)
    unless id.is_a?(Integer) && id >= 0 && id <= MAX_ID
      raise ArgumentError, "id must be a 32-bit unsigned integer"
    end
  end

  def ensure_bitmap(other)
    unless other.is_a?(self.class)
      raise ArgumentError, "argument must be a #{self.class}"
    end
  end
end
