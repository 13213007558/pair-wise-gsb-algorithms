=begin rdoc
  A Roaring Bitmap stores a set of 32-bit unsigned integers in a compressed,
  two-level structure. The high 16 bits of a value select a container and the
  low 16 bits are stored inside that container. Each container independently
  uses one of three representations, whichever is the most compact:

  * Array  - a sorted array of 16-bit values (sparse containers, up to 4096 values)
  * Bitmap - a fixed 65536-bit bitmap (dense containers)
  * Run    - a sorted list of inclusive [first, last] runs (clustered values)

  Containers switch representation automatically as values are added and
  removed: growing a dense range switches to a run or bitmap container, while
  deleting values can shrink a container back to a sparse array.

  Supports insertion, deletion, membership tests, set operations
  (intersection, union, difference), rank/select queries and the portable
  serialization format used by the Java and C RoaringBitmap implementations,
  so bytes can be exchanged with those libraries.

    rb = Containers::RoaringBitmap.new
    rb.add(42)
    rb << 100 << 101
    rb.include?(42)          #=> true
    rb.rank(100)             #=> 2 (number of values <= 100)
    rb.select(0)             #=> 42 (smallest value)
    bytes = rb.serialize
    copy = Containers::RoaringBitmap.deserialize(bytes)
=end
class Containers::RoaringBitmap
  include Enumerable

  MAX_UINT32 = (1 << 32) - 1
  ARRAY_LIMIT = 4096
  CONTAINER_BITS = 1 << 16
  BITMAP_WORDS = CONTAINER_BITS / 64
  BITMAP_BYTES = BITMAP_WORDS * 8

  SERIAL_COOKIE = 12346
  SERIAL_COOKIE_RUN = 12347
  NO_OFFSET_THRESHOLD = 4

  TYPE_RANK = { :array => 0, :run => 1, :bitmap => 2 }.freeze

  # Creates a new, empty Roaring Bitmap, optionally initialized with an
  # enumerable of uint32 values.
  #
  #   rb = Containers::RoaringBitmap.new([1, 2, 3, 65536])
  def initialize(values = nil)
    @keys = []        # sorted high-16-bit keys
    @containers = []  # container holding the low 16 bits of each key
    @cardinality = 0
    values.each { |value| add(value) } if values
  end

  # Number of values stored in the bitmap.
  attr_reader :cardinality
  alias_method :size, :cardinality
  alias_method :length, :cardinality

  def empty?
    @cardinality == 0
  end

  # Adds a uint32 value to the bitmap. Returns self.
  #
  #   rb.add(42)
  #   rb << 43 # does the same thing
  def add(value)
    value = check_uint32(value)
    key = value >> 16
    low = value & 0xFFFF
    found, position = key_position(key)
    if found
      container = @containers[position]
      return self unless container.add(low)
      @containers[position] = normalize(container)
    else
      @keys.insert(position, key)
      @containers.insert(position, ArrayContainer.new([low]))
    end
    @cardinality += 1
    self
  end
  alias_method :<<, :add

  # Removes a uint32 value from the bitmap. Returns self.
  def remove(value)
    value = check_uint32(value)
    key = value >> 16
    low = value & 0xFFFF
    found, position = key_position(key)
    return self unless found
    container = @containers[position]
    return self unless container.remove(low)
    @cardinality -= 1
    if container.cardinality == 0
      @keys.delete_at(position)
      @containers.delete_at(position)
    else
      @containers[position] = normalize(container)
    end
    self
  end
  alias_method :delete, :remove

  # Returns true if the uint32 value is present in the bitmap.
  def include?(value)
    value = check_uint32(value)
    found, position = key_position(value >> 16)
    found ? @containers[position].include?(value & 0xFFFF) : false
  end
  alias_method :member?, :include?
  alias_method :contains?, :include?

  # Iterates over the values in ascending order.
  def each
    return enum_for(:each) unless block_given?
    @keys.each_with_index do |key, index|
      base = key << 16
      @containers[index].each { |low| yield base | low }
    end
    self
  end

  # Returns the values in ascending order as an Array.
  def to_a
    values = []
    each { |value| values << value }
    values
  end

  # Returns the number of values <= the given uint32 value.
  def rank(value)
    value = check_uint32(value)
    key = value >> 16
    low = value & 0xFFFF
    count = 0
    @keys.each_with_index do |container_key, index|
      break if container_key > key
      container = @containers[index]
      count += container_key == key ? container.rank(low) : container.cardinality
    end
    count
  end

  # Returns the value at the given 0-based rank (the index-th smallest
  # value), or nil if the index is out of range.
  def select(index)
    raise ArgumentError, "index must be an Integer" unless index.is_a?(Integer)
    return nil if index < 0 || index >= @cardinality
    @containers.each_with_index do |container, i|
      return (@keys[i] << 16) | container.select(index) if index < container.cardinality
      index -= container.cardinality
    end
    nil
  end

  # Returns a new bitmap with the values present in both bitmaps.
  def intersection(other)
    check_bitmap(other)
    result = self.class.new
    i = j = 0
    other_keys = other.keys
    other_containers = other.containers
    while i < @keys.size && j < other_keys.size
      if @keys[i] == other_keys[j]
        result.push_container(@keys[i], container_intersection(@containers[i], other_containers[j]))
        i += 1
        j += 1
      elsif @keys[i] < other_keys[j]
        i += 1
      else
        j += 1
      end
    end
    result
  end
  alias_method :&, :intersection

  # Returns a new bitmap with the values present in either bitmap.
  def union(other)
    check_bitmap(other)
    result = self.class.new
    i = j = 0
    other_keys = other.keys
    other_containers = other.containers
    while i < @keys.size || j < other_keys.size
      if j >= other_keys.size || (i < @keys.size && @keys[i] < other_keys[j])
        result.push_container(@keys[i], @containers[i].dup)
        i += 1
      elsif i >= @keys.size || other_keys[j] < @keys[i]
        result.push_container(other_keys[j], other_containers[j].dup)
        j += 1
      else
        result.push_container(@keys[i], container_union(@containers[i], other_containers[j]))
        i += 1
        j += 1
      end
    end
    result
  end
  alias_method :|, :union

  # Returns a new bitmap with the values present in this bitmap but not
  # in the other bitmap.
  def difference(other)
    check_bitmap(other)
    result = self.class.new
    i = j = 0
    other_keys = other.keys
    other_containers = other.containers
    while i < @keys.size
      if j >= other_keys.size || @keys[i] < other_keys[j]
        result.push_container(@keys[i], @containers[i].dup)
        i += 1
      elsif @keys[i] > other_keys[j]
        j += 1
      else
        result.push_container(@keys[i], container_difference(@containers[i], other_containers[j]))
        i += 1
        j += 1
      end
    end
    result
  end
  alias_method :-, :difference

  # Two bitmaps are equal when they contain the same values, regardless
  # of the container representations used.
  def ==(other)
    other.is_a?(Containers::RoaringBitmap) &&
      @cardinality == other.cardinality &&
      to_a == other.to_a
  end

  # Returns a Hash mapping each high-16-bit key to the type of its
  # container (:array, :bitmap or :run). Useful for introspection.
  def container_types
    types = {}
    @keys.each_with_index { |key, index| types[key] = @containers[index].type }
    types
  end

  # Serializes the bitmap using the portable RoaringBitmap format,
  # compatible with the Java and C implementations. Returns a binary String.
  def serialize
    size = @keys.size
    has_run = @containers.any? { |container| container.type == :run }
    out = String.new(encoding: Encoding::BINARY)
    if has_run
      out << [SERIAL_COOKIE_RUN | ((size - 1) << 16)].pack("V")
      flags = Array.new((size + 7) / 8, 0)
      @containers.each_with_index do |container, index|
        flags[index >> 3] |= 1 << (index & 7) if container.type == :run
      end
      out << flags.pack("C*")
    else
      out << [SERIAL_COOKIE, size].pack("V2")
    end
    @keys.each_with_index do |key, index|
      out << [key, @containers[index].cardinality - 1].pack("v2")
    end
    data = @containers.map { |container| container.serialize }
    if !has_run || size >= NO_OFFSET_THRESHOLD
      offset = out.bytesize + 4 * size
      data.each do |bytes|
        out << [offset].pack("V")
        offset += bytes.bytesize
      end
    end
    data.each { |bytes| out << bytes }
    out
  end

  # Builds a bitmap from bytes produced by #serialize (or by the portable
  # serialization of another RoaringBitmap implementation). Raises
  # ArgumentError when the input is not a valid serialized bitmap.
  def self.deserialize(bytes)
    raise ArgumentError, "serialized bitmap must be a String" unless bytes.is_a?(String)
    bitmap = new
    bitmap.send(:deserialize_from, bytes.b)
    bitmap
  end

  def initialize_copy(other)
    super
    @keys = other.keys.dup
    @containers = other.containers.map(&:dup)
    @cardinality = other.cardinality
  end

  protected

  attr_reader :keys, :containers

  # Appends a normalized, non-empty container. Keys must be appended in
  # strictly increasing order.
  def push_container(key, container)
    return if container.nil? || container.cardinality == 0
    container = normalize(container)
    @keys << key
    @containers << container
    @cardinality += container.cardinality
  end

  private

  def check_uint32(value)
    unless value.is_a?(Integer) && value >= 0 && value <= MAX_UINT32
      raise ArgumentError, "value must be an Integer in 0..#{MAX_UINT32}, got #{value.inspect}"
    end
    value
  end

  def check_bitmap(other)
    unless other.is_a?(Containers::RoaringBitmap)
      raise ArgumentError, "argument must be a Containers::RoaringBitmap"
    end
  end

  # Returns [found, position]; when not found, position is the index at
  # which the key should be inserted.
  def key_position(key)
    index = @keys.bsearch_index { |container_key| container_key >= key }
    index ||= @keys.size
    [@keys[index] == key, index]
  end

  # Picks the most compact representation for the container, converting
  # it when another type would serialize to fewer bytes.
  def normalize(container)
    cardinality = container.cardinality
    run_bytes = 4 + 4 * container.run_count
    target =
      if cardinality <= ARRAY_LIMIT
        run_bytes < 2 * cardinality ? :run : :array
      else
        run_bytes < BITMAP_BYTES ? :run : :bitmap
      end
    container.type == target ? container : convert_container(container, target)
  end

  def convert_container(container, target)
    case target
    when :array then ArrayContainer.new(container.to_a)
    when :run then RunContainer.from_values(container.each)
    when :bitmap then BitmapContainer.from_values(container.each)
    end
  end

  def container_intersection(a_container, b_container)
    if TYPE_RANK[a_container.type] > TYPE_RANK[b_container.type]
      a_container, b_container = b_container, a_container
    end
    case [a_container.type, b_container.type]
    when [:array, :array]
      ArrayContainer.new(intersect_sorted(a_container.to_a, b_container.to_a))
    when [:array, :run], [:array, :bitmap]
      ArrayContainer.new(a_container.to_a.select { |value| b_container.include?(value) })
    when [:run, :run]
      RunContainer.new(intersect_runs(a_container.runs, b_container.runs))
    when [:run, :bitmap]
      bitmap_masked_to_runs(b_container, a_container.runs)
    when [:bitmap, :bitmap]
      words = Array.new(BITMAP_WORDS) { |i| a_container.words[i] & b_container.words[i] }
      BitmapContainer.new(words)
    end
  end

  def container_union(a_container, b_container)
    if a_container.type == :array && b_container.type == :array
      return ArrayContainer.new(union_sorted(a_container.to_a, b_container.to_a))
    end
    if a_container.type == :run && b_container.type == :run
      return RunContainer.new(union_runs(a_container.runs, b_container.runs))
    end
    if a_container.type == :bitmap || b_container.type == :bitmap
      bitmap = a_container.type == :bitmap ? a_container : b_container
      other = a_container.type == :bitmap ? b_container : a_container
      words = bitmap.words.dup
      other.each { |value| words[value >> 6] |= 1 << (value & 63) }
      return BitmapContainer.new(words)
    end
    run = (a_container.type == :run ? a_container : b_container).dup
    array = a_container.type == :array ? a_container : b_container
    array.each { |value| run.add(value) }
    run
  end

  def container_difference(a_container, b_container)
    case a_container.type
    when :array
      values =
        if b_container.type == :array
          difference_sorted(a_container.to_a, b_container.to_a)
        else
          a_container.to_a.reject { |value| b_container.include?(value) }
        end
      ArrayContainer.new(values)
    when :run
      case b_container.type
      when :run
        RunContainer.new(difference_runs(a_container.runs, b_container.runs))
      when :array
        result = a_container.dup
        b_container.each { |value| result.remove(value) }
        result
      when :bitmap
        words = bitmap_words_for(a_container)
        b_container.words.each_with_index { |word, i| words[i] &= ~word }
        BitmapContainer.new(words)
      end
    when :bitmap
      words = a_container.words.dup
      case b_container.type
      when :bitmap
        b_container.words.each_with_index { |word, i| words[i] &= ~word }
      when :array
        b_container.each { |value| words[value >> 6] &= ~(1 << (value & 63)) }
      when :run
        clear_run_ranges(words, b_container.runs)
      end
      BitmapContainer.new(words)
    end
  end

  def intersect_sorted(a_values, b_values)
    result = []
    i = j = 0
    while i < a_values.size && j < b_values.size
      if a_values[i] == b_values[j]
        result << a_values[i]
        i += 1
        j += 1
      elsif a_values[i] < b_values[j]
        i += 1
      else
        j += 1
      end
    end
    result
  end

  def union_sorted(a_values, b_values)
    result = []
    i = j = 0
    while i < a_values.size && j < b_values.size
      if a_values[i] == b_values[j]
        result << a_values[i]
        i += 1
        j += 1
      elsif a_values[i] < b_values[j]
        result << a_values[i]
        i += 1
      else
        result << b_values[j]
        j += 1
      end
    end
    result.concat(a_values[i..-1]) if i < a_values.size
    result.concat(b_values[j..-1]) if j < b_values.size
    result
  end

  def difference_sorted(a_values, b_values)
    result = []
    i = j = 0
    while i < a_values.size
      if j >= b_values.size || a_values[i] < b_values[j]
        result << a_values[i]
        i += 1
      elsif a_values[i] > b_values[j]
        j += 1
      else
        i += 1
        j += 1
      end
    end
    result
  end

  def intersect_runs(a_runs, b_runs)
    result = []
    i = j = 0
    while i < a_runs.size && j < b_runs.size
      first = a_runs[i][0] > b_runs[j][0] ? a_runs[i][0] : b_runs[j][0]
      last = a_runs[i][1] < b_runs[j][1] ? a_runs[i][1] : b_runs[j][1]
      result << [first, last] if first <= last
      if a_runs[i][1] < b_runs[j][1]
        i += 1
      else
        j += 1
      end
    end
    result
  end

  def union_runs(a_runs, b_runs)
    merged = []
    i = j = 0
    while i < a_runs.size || j < b_runs.size
      if j >= b_runs.size || (i < a_runs.size && a_runs[i][0] <= b_runs[j][0])
        run = a_runs[i]
        i += 1
      else
        run = b_runs[j]
        j += 1
      end
      if merged.empty? || run[0] > merged[-1][1] + 1
        merged << run.dup
      elsif run[1] > merged[-1][1]
        merged[-1][1] = run[1]
      end
    end
    merged
  end

  def difference_runs(a_runs, b_runs)
    result = []
    j = 0
    a_runs.each do |first, last|
      current = first
      j += 1 while j < b_runs.size && b_runs[j][1] < current
      k = j
      while k < b_runs.size && b_runs[k][0] <= last
        result << [current, b_runs[k][0] - 1] if b_runs[k][0] > current
        current = b_runs[k][1] + 1
        break if current > last
        k += 1
      end
      result << [current, last] if current <= last
    end
    result
  end

  def bitmap_words_for(container)
    words = Array.new(BITMAP_WORDS, 0)
    container.each { |value| words[value >> 6] |= 1 << (value & 63) }
    words
  end

  def bitmap_masked_to_runs(bitmap, runs)
    words = Array.new(BITMAP_WORDS, 0)
    source = bitmap.words
    each_run_word_mask(runs) do |word_index, mask|
      words[word_index] |= source[word_index] & mask
    end
    BitmapContainer.new(words)
  end

  def clear_run_ranges(words, runs)
    each_run_word_mask(runs) do |word_index, mask|
      words[word_index] &= ~mask
    end
    words
  end

  # Yields [word_index, mask] for each 64-bit word touched by the runs.
  # A word may be yielded more than once when several runs touch it.
  def each_run_word_mask(runs)
    runs.each do |first, last|
      word_index = first >> 6
      last_word = last >> 6
      while word_index <= last_word
        word_start = word_index << 6
        run_first = first > word_start ? first - word_start : 0
        run_last = last - word_start < 63 ? last - word_start : 63
        mask = ((1 << (run_last - run_first + 1)) - 1) << run_first
        yield word_index, mask
        word_index += 1
      end
    end
  end

  def deserialize_from(bytes)
    position = 0
    read = lambda do |length|
      if position + length > bytes.bytesize
        raise ArgumentError, "invalid serialized bitmap: unexpected end of data"
      end
      chunk = bytes.byteslice(position, length)
      position += length
      chunk
    end

    cookie = read.call(4).unpack1("V")
    run_flags = nil
    if (cookie & 0xFFFF) == SERIAL_COOKIE_RUN
      size = (cookie >> 16) + 1
      run_flags = read.call((size + 7) / 8).unpack("C*")
    elsif cookie == SERIAL_COOKIE
      size = read.call(4).unpack1("V")
    else
      raise ArgumentError, "invalid serialized bitmap: bad cookie"
    end

    keys = []
    cardinalities = []
    size.times do
      key, cardinality_minus_one = read.call(4).unpack("v2")
      if !keys.empty? && key <= keys[-1]
        raise ArgumentError, "invalid serialized bitmap: keys are not increasing"
      end
      keys << key
      cardinalities << cardinality_minus_one + 1
    end

    has_offsets = run_flags ? size >= NO_OFFSET_THRESHOLD : true
    read.call(4 * size) if has_offsets

    size.times do |index|
      is_run = run_flags && (run_flags[index >> 3] & (1 << (index & 7))) != 0
      container =
        if is_run
          deserialize_run_container(read, cardinalities[index])
        elsif cardinalities[index] <= ARRAY_LIMIT
          values = read.call(2 * cardinalities[index]).unpack("v*")
          values.each_cons(2) do |former, latter|
            if latter <= former
              raise ArgumentError, "invalid serialized bitmap: array container not sorted"
            end
          end
          ArrayContainer.new(values)
        else
          container = BitmapContainer.new(read.call(BITMAP_BYTES).unpack("Q<*"))
          if container.cardinality != cardinalities[index]
            raise ArgumentError, "invalid serialized bitmap: bitmap cardinality mismatch"
          end
          container
        end
      @keys << keys[index]
      @containers << container
      @cardinality += container.cardinality
    end

    if position != bytes.bytesize
      raise ArgumentError, "invalid serialized bitmap: trailing bytes"
    end
    self
  end

  def deserialize_run_container(read, expected_cardinality)
    run_count = read.call(2).unpack1("v")
    pairs = read.call(4 * run_count).unpack("v*")
    runs = []
    run_count.times do |i|
      first = pairs[2 * i]
      last = first + pairs[2 * i + 1]
      if last >= CONTAINER_BITS || (!runs.empty? && first <= runs[-1][1])
        raise ArgumentError, "invalid serialized bitmap: corrupt run container"
      end
      runs << [first, last]
    end
    container = RunContainer.new(runs)
    if container.cardinality != expected_cardinality
      raise ArgumentError, "invalid serialized bitmap: run cardinality mismatch"
    end
    container
  end

  # Sorted array of 16-bit values. Used for sparse containers.
  class ArrayContainer
    attr_reader :cardinality, :run_count

    # Internal: exposed for container operations.
    attr_reader :values

    def initialize(values)
      @values = values
      @cardinality = values.size
      @run_count = compute_run_count
    end

    def type
      :array
    end

    def include?(value)
      index = @values.bsearch_index { |element| element >= value }
      !index.nil? && @values[index] == value
    end

    def add(value)
      index = @values.bsearch_index { |element| element >= value }
      return false if index && @values[index] == value
      index ||= @values.size
      left = index > 0 && @values[index - 1] == value - 1
      right = index < @values.size && @values[index] == value + 1
      @run_count += 1 unless left || right
      @run_count -= 1 if left && right
      @values.insert(index, value)
      @cardinality += 1
      true
    end

    def remove(value)
      index = @values.bsearch_index { |element| element >= value }
      return false unless index && @values[index] == value
      left = index > 0 && @values[index - 1] == value - 1
      right = index < @values.size - 1 && @values[index + 1] == value + 1
      @run_count += 1 if left && right
      @run_count -= 1 unless left || right
      @values.delete_at(index)
      @cardinality -= 1
      true
    end

    def each
      return enum_for(:each) unless block_given?
      @values.each { |value| yield value }
    end

    def to_a
      @values.dup
    end

    def rank(value)
      index = @values.bsearch_index { |element| element > value }
      index || @values.size
    end

    def select(index)
      @values[index]
    end

    def serialize
      @values.pack("v*")
    end

    def initialize_copy(other)
      super
      @values = other.values.dup
    end

    private

    def compute_run_count
      count = 0
      previous = nil
      @values.each do |value|
        count += 1 if previous.nil? || value != previous + 1
        previous = value
      end
      count
    end
  end

  # Fixed 65536-bit bitmap. Used for dense containers.
  class BitmapContainer
    attr_reader :cardinality, :run_count

    # Internal: exposed for container operations.
    attr_reader :words

    def initialize(words, cardinality = nil, run_count = nil)
      @words = words
      @cardinality = cardinality || compute_cardinality
      @run_count = run_count || compute_run_count
    end

    def self.from_values(values)
      words = Array.new(BITMAP_WORDS, 0)
      values.each { |value| words[value >> 6] |= 1 << (value & 63) }
      new(words)
    end

    def self.popcount(word)
      word -= (word >> 1) & 0x5555555555555555
      word = (word & 0x3333333333333333) + ((word >> 2) & 0x3333333333333333)
      word = (word + (word >> 4)) & 0x0F0F0F0F0F0F0F0F
      ((word * 0x0101010101010101) >> 56) & 0xFF
    end

    def type
      :bitmap
    end

    def include?(value)
      (@words[value >> 6] & (1 << (value & 63))) != 0
    end

    def add(value)
      word_index = value >> 6
      bit = 1 << (value & 63)
      return false if (@words[word_index] & bit) != 0
      @words[word_index] |= bit
      @cardinality += 1
      update_run_count(value, 1)
      true
    end

    def remove(value)
      word_index = value >> 6
      bit = 1 << (value & 63)
      return false if (@words[word_index] & bit) == 0
      @words[word_index] &= ~bit
      @cardinality -= 1
      update_run_count(value, -1)
      true
    end

    def each
      return enum_for(:each) unless block_given?
      @words.each_with_index do |word, word_index|
        next if word == 0
        base = word_index << 6
        while word != 0
          lowest = word & -word
          yield base + lowest.bit_length - 1
          word ^= lowest
        end
      end
    end

    def to_a
      values = []
      each { |value| values << value }
      values
    end

    def rank(value)
      word_index = value >> 6
      count = 0
      i = 0
      while i < word_index
        count += self.class.popcount(@words[i])
        i += 1
      end
      mask = (2 << (value & 63)) - 1
      count + self.class.popcount(@words[word_index] & mask)
    end

    def select(index)
      @words.each_with_index do |word, word_index|
        next if word == 0
        count = self.class.popcount(word)
        if index < count
          while index > 0
            word &= word - 1
            index -= 1
          end
          return (word_index << 6) + (word & -word).bit_length - 1
        end
        index -= count
      end
      nil
    end

    def serialize
      @words.pack("Q<*")
    end

    def initialize_copy(other)
      super
      @words = other.words.dup
    end

    private

    # direction is +1 when the bit at value was set, -1 when cleared.
    def update_run_count(value, direction)
      left = value > 0 && include?(value - 1)
      right = value < CONTAINER_BITS - 1 && include?(value + 1)
      if left && right
        @run_count -= direction
      elsif !left && !right
        @run_count += direction
      end
    end

    def compute_cardinality
      count = 0
      @words.each { |word| count += self.class.popcount(word) }
      count
    end

    def compute_run_count
      count = 0
      previous_bit = 0
      @words.each do |word|
        count += self.class.popcount(word & ~((word << 1) | previous_bit))
        previous_bit = word >> 63
      end
      count
    end
  end

  # Sorted list of inclusive [first, last] runs. Used for clustered values.
  class RunContainer
    attr_reader :cardinality

    # Internal: exposed for container operations.
    attr_reader :runs

    def initialize(runs)
      @runs = runs
      @cardinality = 0
      runs.each { |first, last| @cardinality += last - first + 1 }
    end

    def self.from_values(values)
      runs = []
      values.each do |value|
        if runs.empty? || value > runs[-1][1] + 1
          runs << [value, value]
        else
          runs[-1][1] = value
        end
      end
      new(runs)
    end

    def type
      :run
    end

    def run_count
      @runs.size
    end

    def include?(value)
      !run_index_for(value).nil?
    end

    def add(value)
      low = 0
      high = @runs.size
      while low < high
        mid = (low + high) >> 1
        if @runs[mid][1] < value - 1
          low = mid + 1
        else
          high = mid
        end
      end
      index = low
      if index < @runs.size
        first, last = @runs[index]
        return false if value >= first && value <= last
        if value == last + 1
          if index + 1 < @runs.size && @runs[index + 1][0] == value + 1
            @runs[index][1] = @runs[index + 1][1]
            @runs.delete_at(index + 1)
          else
            @runs[index][1] = value
          end
          @cardinality += 1
          return true
        end
        if value + 1 == first
          @runs[index][0] = value
          @cardinality += 1
          return true
        end
      end
      @runs.insert(index, [value, value])
      @cardinality += 1
      true
    end

    def remove(value)
      index = run_index_for(value)
      return false if index.nil?
      first, last = @runs[index]
      @cardinality -= 1
      if first == last
        @runs.delete_at(index)
      elsif value == first
        @runs[index][0] = first + 1
      elsif value == last
        @runs[index][1] = last - 1
      else
        @runs[index] = [first, value - 1]
        @runs.insert(index + 1, [value + 1, last])
      end
      true
    end

    def each
      return enum_for(:each) unless block_given?
      @runs.each do |first, last|
        value = first
        while value <= last
          yield value
          value += 1
        end
      end
    end

    def to_a
      values = []
      each { |value| values << value }
      values
    end

    def rank(value)
      count = 0
      @runs.each do |first, last|
        break if value < first
        if value > last
          count += last - first + 1
        else
          count += value - first + 1
          break
        end
      end
      count
    end

    def select(index)
      @runs.each do |first, last|
        length = last - first + 1
        return first + index if index < length
        index -= length
      end
      nil
    end

    def serialize
      bytes = [@runs.size].pack("v")
      @runs.each { |first, last| bytes << [first, last - first].pack("v2") }
      bytes
    end

    def initialize_copy(other)
      super
      @runs = other.runs.map(&:dup)
    end

    private

    # Returns the index of the run containing value, or nil.
    def run_index_for(value)
      low = 0
      high = @runs.size - 1
      while low <= high
        mid = (low + high) >> 1
        run = @runs[mid]
        if value < run[0]
          high = mid - 1
        elsif value > run[1]
          low = mid + 1
        else
          return mid
        end
      end
      nil
    end
  end
end
