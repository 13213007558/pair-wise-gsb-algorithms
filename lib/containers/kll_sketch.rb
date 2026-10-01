=begin rdoc
    A KLL sketch (Karnin, Lang, Liberty - "Optimal Quantile Approximation in
    Streams", FOCS 2016) is a compact, mergeable summary of a stream of
    numeric values. It answers quantile queries (e.g. "what is the p99
    latency?") using only O(k log(n/k)) retained values instead of storing
    the whole stream.

    Typical use: each worker keeps a local sketch and reports it to a
    central node, which merges the sketches and queries arbitrary quantiles
    of the combined data.

      worker = Containers::KLLSketch.new(k: 200, random: Random.new(seed))
      latencies.each { |x| worker.add(x) }

      center = Containers::KLLSketch.new
      center.merge!(worker_a).merge!(worker_b)
      center.quantile(0.99)   #=> approximate p99 of all values
      center.cdf(120.0)       #=> approximate fraction of values <= 120.0

    The capacity parameter +k+ controls the *rank* error of the answers,
    not the *value* error: a returned quantile is guaranteed (with high
    probability over the sketch's internal random choices) to be close to
    the requested rank in the sorted stream, but nothing is promised about
    how close its numeric value is to the exact quantile value. Where the
    data is flat the value error can be large even when the rank error is
    tiny. Larger +k+ means smaller rank error and more memory; the error
    shrinks roughly like 1/sqrt(k).

    The guarantee is probabilistic. It depends on the random choices made
    during compaction, so the caller supplies the random source. Pass
    Random.new(seed) for reproducible runs, or a SecureRandom-backed source
    in production. A single lucky run does not imply a deterministic
    error bound.

    While no compaction has happened yet (fewer added values than the
    level-0 capacity), the sketch retains every value and answers are
    exact. After compaction the answers are estimates. NaN values are
    rejected, since they have no defined rank.
=end
class Containers::KLLSketch
  # Default capacity parameter. Gives roughly 1-2% normalized rank error.
  DEFAULT_K = 200

  # Capacity of level h shrinks by this factor per level below the top.
  SHRINK_FACTOR = 2.0 / 3.0

  # Every level keeps at least this many values (compaction needs pairs).
  MIN_LEVEL_CAPACITY = 2

  attr_reader :k, :n, :min, :max

  # call-seq:
  #     KLLSketch.new(k: 200, random: Random.new) -> new_sketch
  #
  # +k+ is the capacity parameter controlling rank error (larger is more
  # accurate and uses more memory). +random+ is the random source used for
  # compaction decisions; it must respond to #rand (e.g. Random.new(seed)).
  def initialize(k: DEFAULT_K, random: Random.new)
    unless k.is_a?(Integer) && k >= MIN_LEVEL_CAPACITY
      raise ArgumentError, "k must be an Integer >= #{MIN_LEVEL_CAPACITY}"
    end
    unless random.respond_to?(:rand)
      raise ArgumentError, "random must respond to #rand, e.g. Random.new(seed)"
    end
    @k = k
    @random = random
    @levels = [[]] # level h holds values with weight 2**h
    @n = 0
    @min = nil
    @max = nil
  end

  # call-seq:
  #     add(value) -> self
  #
  # Adds a value to the sketch. NaN is rejected with ArgumentError because
  # it has no defined rank. Values must be mutually comparable.
  def add(value)
    if value.respond_to?(:nan?) && value.nan?
      raise ArgumentError, "NaN cannot be added to a KLL sketch"
    end
    @levels[0] << value
    @n += 1
    @min = value if @min.nil? || (value <=> @min) < 0
    @max = value if @max.nil? || (value <=> @max) > 0
    compress if @levels[0].size > capacity(0)
    self
  end
  alias_method :<<, :add

  # call-seq:
  #     merge!(other) -> self
  #
  # Merges +other+ into this sketch; the result summarizes the union of
  # both streams. Sketches with different sizes and different +k+ values
  # can be merged; the result keeps this sketch's +k+. Merging an empty
  # sketch is a no-op.
  def merge!(other)
    unless other.is_a?(Containers::KLLSketch)
      raise TypeError, "can only merge another Containers::KLLSketch"
    end
    return self if other.n == 0

    @levels << [] while @levels.size < other.levels.size
    other.levels.each_with_index { |buffer, h| @levels[h].concat(buffer) }
    @n += other.n
    @min = other.min if @min.nil? || (other.min <=> @min) < 0
    @max = other.max if @max.nil? || (other.max <=> @max) > 0
    compress
    self
  end

  # call-seq:
  #     merge(other) -> new_sketch
  #
  # Non-destructive version of merge!: returns a new sketch summarizing
  # the union of both streams, leaving both sketches unchanged.
  def merge(other)
    dup.merge!(other)
  end

  # call-seq:
  #     quantile(phi) -> value or nil
  #
  # Returns the estimated value at normalized rank +phi+ (0.5 => median),
  # using the nearest-rank convention: the smallest retained value whose
  # cumulative weight reaches ceil(phi * n). The extremes are exact:
  # quantile(0.0) always returns min and quantile(1.0) always returns max.
  # Interior quantiles are exact while the sketch is still uncompressed
  # and estimates afterwards. Returns nil for an empty sketch.
  def quantile(phi)
    return nil if empty?
    unless phi.is_a?(Numeric) && phi >= 0 && phi <= 1
      raise ArgumentError, "phi must be a number in [0, 1]"
    end
    return @min if phi == 0
    return @max if phi == 1
    target = [(phi * @n).ceil, 1].max
    cumulative = 0
    weighted_items.each do |value, weight|
      cumulative += weight
      return value if cumulative >= target
    end
    @max
  end

  # call-seq:
  #     rank(value) -> int
  #
  # Estimated number of stream values <= +value+. Exact while the sketch
  # is uncompressed. Returns 0 for an empty sketch.
  def rank(value)
    total = 0
    @levels.each_with_index do |buffer, h|
      weight = 1 << h
      buffer.each { |v| total += weight if (v <=> value) <= 0 }
    end
    total
  end

  # call-seq:
  #     cdf(value) -> float or nil
  #
  # Estimated fraction of stream values <= +value+, i.e. rank(value) / n.
  # Returns nil for an empty sketch.
  def cdf(value)
    return nil if empty?
    rank(value).to_f / @n
  end

  # Number of values currently retained by the sketch (<= n). Equal to n
  # while the sketch is still exact.
  def num_retained
    @levels.sum(&:size)
  end

  def empty?
    @n.zero?
  end

  def size
    @n
  end
  alias_method :length, :size

  protected

  attr_reader :levels

  private

  def initialize_copy(other)
    super
    @levels = other.levels.map(&:dup)
  end

  # Capacity of level h: full k at the top level, shrinking by
  # SHRINK_FACTOR per level below it, never below MIN_LEVEL_CAPACITY.
  def capacity(h)
    [(k * (SHRINK_FACTOR**(@levels.size - 1 - h))).ceil, MIN_LEVEL_CAPACITY].max
  end

  # Compacts any level that has grown beyond its capacity, bottom-up.
  def compress
    h = 0
    while h < @levels.size
      if @levels[h].size > capacity(h)
        compact_level(h)
        h = 0 # a new top level shrinks every capacity; rescan
      else
        h += 1
      end
    end
  end

  # Sorts the level, sets aside one random element if the size is odd,
  # then promotes every second element (random offset) to the next level.
  def compact_level(h)
    buffer = @levels[h].sort!
    spare = buffer.delete_at(@random.rand(buffer.size)) if buffer.size.odd?
    offset = @random.rand(2)
    @levels << [] if h + 1 == @levels.size
    promoted = @levels[h + 1]
    i = offset
    while i < buffer.size
      promoted << buffer[i]
      i += 2
    end
    buffer.clear
    buffer << spare if spare
  end

  # All retained [value, weight] pairs, sorted by value.
  def weighted_items
    items = []
    @levels.each_with_index do |buffer, h|
      weight = 1 << h
      buffer.each { |v| items << [v, weight] }
    end
    items.sort_by!(&:first)
    items
  end
end
