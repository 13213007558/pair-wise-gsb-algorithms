=begin rdoc
    A Roaring Bitmap stores a set of 32-bit unsigned integers in a compressed
    form. The 32-bit space is split into 2**16 chunks keyed by the high 16
    bits; each chunk is stored in one of three container types:

    * ArrayContainer  - sorted array of 16-bit values, used while a chunk is
                        sparse (at most 4096 values).
    * BitmapContainer - a fixed 8 KB bitmap, used when a chunk is dense.
    * RunContainer    - run-length encoded intervals, used when values form
                        long contiguous ranges (see #run_optimize).

    Containers switch automatically: an ArrayContainer becomes a
    BitmapContainer once it grows past 4096 values, a BitmapContainer drops
    back to an ArrayContainer when deletions make it sparse again, and
    RunContainers are created (or dissolved) by #run_optimize when runs are
    (or stop being) the most compact representation.

    Supports insertion, deletion, membership tests, set operations
    (intersection, union, difference), rank/select queries, and the portable
    serialization format used by the C, Java and Go RoaringBitmap
    implementations, so payloads can be exchanged with them.

    All values must be Integers in the range 0..2**32-1.
=end rdoc
class Containers::RoaringBitmap
  include Enumerable

  UINT32_MAX = (1 << 32) - 1
  UINT16_MAX = (1 << 16) - 1

  # Maximum cardinality of an ArrayContainer before it converts to a
  # BitmapContainer.
  ARRAY_LIMIT = 4096

  # Portable format constants (shared with CRoaring and the Java/Go ports).
  SERIAL_COOKIE_NO_RUN = 12346
  SERIAL_COOKIE_RUN = 12347
  NO_OFFSET_THRESHOLD = 4

  BITMAP_BYTES = 8192

  POPCOUNT_BYTE = (0..255).map { |i| i.to_s(2).count("1") }.freeze

  # Raised when serialized input is malformed.
  class DeserializationError < ArgumentError; end

  module ContainerUtil
    module_function

    # Index of the first element >= v in sorted array a.
    def lower_bound(a, v)
      lo = 0
      hi = a.size
      while lo < hi
        mid = (lo + hi) >> 1
        if a[mid] < v
          lo = mid + 1
        else
          hi = mid
        end
      end
      lo
    end
  end

  # Sorted array of 16-bit values. Used for sparse chunks.
  class ArrayContainer
    include Enumerable
    attr_reader :cardinality

    def initialize(values = [])
      @values = values # sorted, unique
      @cardinality = values.size
    end

    def include?(v)
      i = ContainerUtil.lower_bound(@values, v)
      i < @values.size && @values[i] == v
    end

    # Returns true if the value was not already present.
    def add(v)
      i = ContainerUtil.lower_bound(@values, v)
      return false if i < @values.size && @values[i] == v

      @values.insert(i, v)
      @cardinality += 1
      true
    end

    # Returns true if the value was present.
    def delete(v)
      i = ContainerUtil.lower_bound(@values, v)
      return false unless i < @values.size && @values[i] == v

      @values.delete_at(i)
      @cardinality -= 1
      true
    end

    def each(&block)
      return enum_for(:each) unless block

      @values.each(&block)
      self
    end

    def to_a
      @values.dup
    end

    # Number of values <= v.
    def rank(v)
      i = ContainerUtil.lower_bound(@values, v)
      (i < @values.size && @values[i] == v) ? i + 1 : i
    end

    # The i-th smallest value (0-based), or nil.
    def select(i)
      @values[i]
    end

    def serialized_size
      2 * @cardinality
    end

    def serialize_to(out)
      out << @values.pack("v*")
    end

    def self.deserialize(bytes)
      raise DeserializationError, "truncated array container" if bytes.bytesize.odd?

      new(bytes.unpack("v*"))
    end
  end

  # Fixed 8 KB bitmap. Used for dense chunks.
  class BitmapContainer
    include Enumerable
    attr_reader :cardinality

    def initialize(bits = nil, cardinality = nil)
      @bits = bits || ("\x00".b * BITMAP_BYTES)
      @cardinality = cardinality || count_bits
    end

    def self.from_sorted(sorted_values)
      bits = "\x00".b * BITMAP_BYTES
      sorted_values.each do |v|
        bits.setbyte(v >> 3, bits.getbyte(v >> 3) | (1 << (v & 7)))
      end
      new(bits, sorted_values.size)
    end

    def include?(v)
      (@bits.getbyte(v >> 3) & (1 << (v & 7))) != 0
    end

    def add(v)
      byte = v >> 3
      mask = 1 << (v & 7)
      old = @bits.getbyte(byte)
      return false if (old & mask) != 0

      @bits.setbyte(byte, old | mask)
      @cardinality += 1
      true
    end

    def delete(v)
      byte = v >> 3
      mask = 1 << (v & 7)
      old = @bits.getbyte(byte)
      return false if (old & mask).zero?

      @bits.setbyte(byte, old & ~mask)
      @cardinality -= 1
      true
    end

    def each
      return enum_for(:each) unless block_given?

      @bits.bytes.each_with_index do |byte, i|
        next if byte.zero?

        base = i << 3
        8.times do |bit|
          yield(base | bit) if (byte & (1 << bit)) != 0
        end
      end
      self
    end

    def to_a
      each.to_a
    end

    def rank(v)
      byte = v >> 3
      total = 0
      byte.times { |i| total += POPCOUNT_BYTE[@bits.getbyte(i)] }
      total + POPCOUNT_BYTE[@bits.getbyte(byte) & ((1 << ((v & 7) + 1)) - 1)]
    end

    def select(i)
      return nil if i.negative? || i >= @cardinality

      remaining = i
      @bits.bytes.each_with_index do |byte, idx|
        count = POPCOUNT_BYTE[byte]
        if remaining < count
          8.times do |bit|
            next if (byte & (1 << bit)).zero?

            return (idx << 3) | bit if remaining.zero?

            remaining -= 1
          end
        end
        remaining -= count
      end
      nil
    end

    def serialized_size
      BITMAP_BYTES
    end

    def serialize_to(out)
      out << @bits
    end

    def self.deserialize(bytes)
      raise DeserializationError, "truncated bitmap container" unless bytes.bytesize == BITMAP_BYTES

      new(bytes.dup)
    end

    private

    def count_bits
      total = 0
      @bits.each_byte { |b| total += POPCOUNT_BYTE[b] }
      total
    end
  end

  # Run-length encoded sorted, disjoint, non-adjacent [first, last] intervals.
  class RunContainer
    include Enumerable
    attr_reader :cardinality

    def initialize(runs = [])
      @runs = runs # [[first, last], ...] sorted, disjoint, non-adjacent
      @cardinality = runs.sum { |first, last| last - first + 1 }
    end

    def self.from_sorted(sorted_values)
      runs = []
      sorted_values.each do |v|
        if runs.empty? || v > runs[-1][1] + 1
          runs << [v, v]
        else
          runs[-1][1] = v
        end
      end
      new(runs)
    end

    def num_runs
      @runs.size
    end

    def include?(v)
      i = run_index_before(v)
      !i.nil? && v <= @runs[i][1]
    end

    # Returns true if the value was not already present.
    def add(v)
      i = run_index_before(v)
      return false if i && v <= @runs[i][1]

      before = i && @runs[i]
      after = i ? @runs[i + 1] : @runs[0]
      merge_before = before && v == before[1] + 1
      merge_after = after && v + 1 == after[0]

      if merge_before && merge_after
        before[1] = after[1]
        @runs.delete(after)
      elsif merge_before
        before[1] = v
      elsif merge_after
        after[0] = v
      else
        @runs.insert(i ? i + 1 : 0, [v, v])
      end
      @cardinality += 1
      true
    end

    # Returns true if the value was present.
    def delete(v)
      i = run_index_before(v)
      return false if i.nil?

      first, last = @runs[i]
      return false if v > last

      if first == last
        @runs.delete_at(i)
      elsif v == first
        @runs[i][0] = first + 1
      elsif v == last
        @runs[i][1] = last - 1
      else
        @runs[i] = [first, v - 1]
        @runs.insert(i + 1, [v + 1, last])
      end
      @cardinality -= 1
      true
    end

    def each
      return enum_for(:each) unless block_given?

      @runs.each do |first, last|
        (first..last).each { |v| yield v }
      end
      self
    end

    def to_a
      each.to_a
    end

    def rank(v)
      total = 0
      @runs.each do |first, last|
        break if first > v

        total += [v, last].min - first + 1
      end
      total
    end

    def select(i)
      return nil if i.negative? || i >= @cardinality

      remaining = i
      @runs.each do |first, last|
        length = last - first + 1
        return first + remaining if remaining < length

        remaining -= length
      end
      nil
    end

    def serialized_size
      2 + 4 * @runs.size
    end

    def serialize_to(out)
      out << [@runs.size].pack("v")
      @runs.each { |first, last| out << [first, last - first].pack("v v") }
    end

    def self.deserialize(bytes)
      raise DeserializationError, "truncated run container" if bytes.bytesize < 2

      num_runs = bytes.unpack1("v")
      expected = 2 + 4 * num_runs
      raise DeserializationError, "truncated run container" unless bytes.bytesize == expected

      flat = bytes.unpack("x2 v*")
      runs = []
      flat.each_slice(2) { |first, length| runs << [first, first + length] }
      new(runs)
    end

    private

    # Index of the last run whose first value is <= v, or nil.
    def run_index_before(v)
      lo = 0
      hi = @runs.size
      while lo < hi
        mid = (lo + hi) >> 1
        if @runs[mid][0] <= v
          lo = mid + 1
        else
          hi = mid
        end
      end
      lo.zero? ? nil : lo - 1
    end
  end

  attr_reader :keys # high 16 bits of each chunk, sorted (parallel to containers)

  # Create a new RoaringBitmap, optionally seeded with an enumerable of
  # uint32 values.
  #
  #   rb = Containers::RoaringBitmap.new([1, 2, 100_000])
  def initialize(values = nil)
    @keys = []
    @containers = []
    values.each { |v| add(v) } if values
  end

  # Add a uint32 value. Returns self.
  #
  #   rb.add(42)
  #   rb << 42
  def add(value)
    check_uint32(value)
    key = value >> 16
    lo = value & UINT16_MAX
    i = key_index(key)
    if i < @keys.size && @keys[i] == key
      container = @containers[i]
      added = container.add(lo)
      if added && container.is_a?(ArrayContainer) && container.cardinality > ARRAY_LIMIT
        @containers[i] = BitmapContainer.from_sorted(container.to_a)
      end
    else
      @keys.insert(i, key)
      @containers.insert(i, ArrayContainer.new([lo]))
    end
    self
  end
  alias_method :<<, :add
  alias_method :insert, :add

  # Remove a uint32 value. Returns self.
  def delete(value)
    check_uint32(value)
    key = value >> 16
    lo = value & UINT16_MAX
    i = key_index(key)
    return self unless i < @keys.size && @keys[i] == key

    container = @containers[i]
    removed = container.delete(lo)
    if removed
      if container.cardinality.zero?
        @keys.delete_at(i)
        @containers.delete_at(i)
      elsif container.is_a?(BitmapContainer) && container.cardinality <= ARRAY_LIMIT
        @containers[i] = ArrayContainer.new(container.to_a)
      elsif container.is_a?(RunContainer) && container.cardinality <= ARRAY_LIMIT &&
            container.serialized_size > 2 * container.cardinality
        @containers[i] = ArrayContainer.new(container.to_a)
      end
    end
    self
  end
  alias_method :remove, :delete

  # Returns true if the uint32 value is present.
  def include?(value)
    check_uint32(value)
    key = value >> 16
    i = key_index(key)
    return false unless i < @keys.size && @keys[i] == key

    @containers[i].include?(value & UINT16_MAX)
  end
  alias_method :member?, :include?
  alias_method :contains?, :include?

  # Number of values in the bitmap.
  def cardinality
    @containers.sum(&:cardinality)
  end
  alias_method :size, :cardinality
  alias_method :length, :cardinality

  def empty?
    @containers.empty?
  end

  # Iterate over all values in ascending order.
  def each
    return enum_for(:each) unless block_given?

    @keys.each_with_index do |key, i|
      base = key << 16
      @containers[i].each { |lo| yield(base | lo) }
    end
    self
  end

  # Sorted array of all values.
  def to_a
    each.to_a
  end

  # Number of values <= value (value must be a uint32).
  def rank(value)
    check_uint32(value)
    key = value >> 16
    lo = value & UINT16_MAX
    total = 0
    @keys.each_with_index do |k, i|
      break if k > key

      total += k == key ? @containers[i].rank(lo) : @containers[i].cardinality
    end
    total
  end

  # The i-th smallest value (0-based), or nil if out of range.
  def select(i)
    raise TypeError, "index must be an Integer, got #{i.class}" unless i.is_a?(Integer)
    return nil if i.negative?

    remaining = i
    @containers.each_with_index do |container, idx|
      return (@keys[idx] << 16) | container.select(remaining) if remaining < container.cardinality

      remaining -= container.cardinality
    end
    nil
  end

  # Intersection: values present in both bitmaps.
  def &(other)
    combine(other) do |a, b|
      next [] unless a && b

      av = a.to_a
      bv = b.to_a
      result = []
      x = y = 0
      while x < av.size && y < bv.size
        if av[x] == bv[y]
          result << av[x]
          x += 1
          y += 1
        elsif av[x] < bv[y]
          x += 1
        else
          y += 1
        end
      end
      result
    end
  end
  alias_method :intersection, :&

  # Union: values present in either bitmap.
  def |(other)
    combine(other) do |a, b|
      av = a ? a.to_a : []
      bv = b ? b.to_a : []
      result = []
      x = y = 0
      while x < av.size || y < bv.size
        if y >= bv.size || (x < av.size && av[x] < bv[y])
          result << av[x]
          x += 1
        elsif x >= av.size || bv[y] < av[x]
          result << bv[y]
          y += 1
        else
          result << av[x]
          x += 1
          y += 1
        end
      end
      result
    end
  end
  alias_method :union, :|

  # Difference: values present in self but not in other.
  def -(other)
    combine(other) do |a, b|
      next [] unless a
      next a.to_a unless b

      av = a.to_a
      bv = b.to_a
      result = []
      x = y = 0
      while x < av.size
        if y >= bv.size
          result.concat(av[x..])
          break
        elsif av[x] < bv[y]
          result << av[x]
          x += 1
        elsif av[x] > bv[y]
          y += 1
        else
          x += 1
          y += 1
        end
      end
      result
    end
  end
  alias_method :difference, :-

  # Convert containers to RunContainers where runs are the most compact
  # representation, and convert RunContainers back to array/bitmap form when
  # they no longer pay off. Returns self.
  def run_optimize
    @containers.map! do |container|
      card = container.cardinality
      run_size = 2 + 4 * (container.is_a?(RunContainer) ? container.num_runs : count_runs(container))
      plain_size = card > ARRAY_LIMIT ? BITMAP_BYTES : 2 * card
      best = [run_size, plain_size].min
      if best == container.serialized_size
        container
      elsif best == run_size
        RunContainer.from_sorted(container.to_a)
      else
        container_from_sorted(container.to_a)
      end
    end
    self
  end

  # Introspection: the container type (:array, :bitmap or :run) of each
  # chunk, in key order.
  def container_types
    @containers.map do |container|
      case container
      when ArrayContainer then :array
      when BitmapContainer then :bitmap
      when RunContainer then :run
      end
    end
  end

  def ==(other)
    other.is_a?(Containers::RoaringBitmap) && to_a == other.to_a
  end

  # Serialize using the portable format shared with CRoaring and the Java/Go
  # RoaringBitmap implementations. Returns a binary String.
  def serialize
    has_run = @containers.any? { |c| c.is_a?(RunContainer) }
    size = @keys.size
    out = String.new(encoding: Encoding::BINARY)
    if has_run
      out << [SERIAL_COOKIE_RUN, size - 1].pack("V V")
      flags = "\x00".b * ((size + 7) / 8)
      @containers.each_with_index do |container, i|
        next unless container.is_a?(RunContainer)

        flags.setbyte(i >> 3, flags.getbyte(i >> 3) | (1 << (i & 7)))
      end
      out << flags
    else
      out << [SERIAL_COOKIE_NO_RUN, (size - 1) & 0xFFFFFFFF].pack("V V")
    end
    @keys.each_with_index do |key, i|
      out << [key, @containers[i].cardinality - 1].pack("v v")
    end
    if !has_run || size >= NO_OFFSET_THRESHOLD
      offset = out.bytesize + 4 * size
      @containers.each do |container|
        out << [offset].pack("V")
        offset += container.serialized_size
      end
    end
    @containers.each { |container| container.serialize_to(out) }
    out
  end
  alias_method :dump, :serialize

  # Inverse of #serialize. Raises DeserializationError on malformed input.
  def self.deserialize(str)
    raise ArgumentError, "expected a String, got #{str.class}" unless str.is_a?(String)

    bytes = str.b
    pos = 0
    read = lambda do |n|
      raise DeserializationError, "unexpected end of input" if pos + n > bytes.bytesize

      chunk = bytes.byteslice(pos, n)
      pos += n
      chunk
    end

    cookie = read.call(4).unpack1("V")
    run_flags = nil
    case cookie
    when SERIAL_COOKIE_RUN
      size = read.call(4).unpack1("V") + 1
      run_flags = read.call((size + 7) / 8)
    when SERIAL_COOKIE_NO_RUN
      size = (read.call(4).unpack1("V") + 1) & 0xFFFFFFFF
    else
      raise DeserializationError, "invalid cookie #{cookie}"
    end

    keys = []
    cards = []
    size.times do
      key, card = read.call(4).unpack("v v")
      keys << key
      cards << card + 1
    end

    read.call(4 * size) if cookie == SERIAL_COOKIE_NO_RUN || size >= NO_OFFSET_THRESHOLD

    containers = []
    size.times do |i|
      is_run = run_flags && (run_flags.getbyte(i >> 3) & (1 << (i & 7))) != 0
      containers <<
        if is_run
          raise DeserializationError, "unexpected end of input" if pos + 2 > bytes.bytesize

          num_runs = bytes.byteslice(pos, 2).unpack1("v")
          RunContainer.deserialize(read.call(2 + 4 * num_runs))
        elsif cards[i] > ARRAY_LIMIT
          BitmapContainer.deserialize(read.call(BITMAP_BYTES))
        else
          ArrayContainer.deserialize(read.call(2 * cards[i]))
        end
    end

    bitmap = allocate
    bitmap.instance_variable_set(:@keys, keys)
    bitmap.instance_variable_set(:@containers, containers)
    bitmap
  end
  class << self
    alias_method :load, :deserialize
  end

  protected

  attr_reader :containers

  private

  def check_uint32(value)
    raise TypeError, "value must be an Integer, got #{value.class}" unless value.is_a?(Integer)
    raise RangeError, "value #{value} is out of uint32 range 0..#{UINT32_MAX}" if value.negative? || value > UINT32_MAX

    value
  end

  # Index of key in @keys, or the insertion point keeping @keys sorted.
  def key_index(key)
    ContainerUtil.lower_bound(@keys, key)
  end

  def container_from_sorted(sorted_values)
    if sorted_values.size > ARRAY_LIMIT
      BitmapContainer.from_sorted(sorted_values)
    else
      ArrayContainer.new(sorted_values)
    end
  end

  def count_runs(container)
    runs = 0
    previous = nil
    container.each do |v|
      runs += 1 if previous.nil? || v != previous + 1
      previous = v
    end
    runs
  end

  # Merge-join over the chunks of both bitmaps. The block receives the two
  # containers (either may be nil) for a shared key and must return a sorted
  # array of 16-bit values for the result chunk (empty to omit it).
  def combine(other)
    raise ArgumentError, "expected a RoaringBitmap" unless other.is_a?(Containers::RoaringBitmap)

    result = self.class.new
    i = j = 0
    while i < @keys.size || j < other.keys.size
      if j >= other.keys.size || (i < @keys.size && @keys[i] < other.keys[j])
        key = @keys[i]
        values = yield(@containers[i], nil)
        i += 1
      elsif i >= @keys.size || other.keys[j] < @keys[i]
        key = other.keys[j]
        values = yield(nil, other.containers[j])
        j += 1
      else
        key = @keys[i]
        values = yield(@containers[i], other.containers[j])
        i += 1
        j += 1
      end
      next if values.empty?

      result.keys << key
      result.containers << container_from_sorted(values)
    end
    result
  end
end
