=begin rdoc
    A KLL sketch (Karn, Lang, Liberty - "Optimal Quantile Approximation in Streams",
    FOCS 2016) is a mergeable randomized summary that answers quantile and rank
    queries over a stream of values using sub-linear space.

    It is meant for the "workers report summaries, the center estimates quantiles
    of the full latency distribution" pattern: each worker keeps one sketch,
    the center merges them and queries quantiles of the union.

    The capacity parameter +k+ controls the *rank* error of the answers, not the
    *value* error: with capacity k the sketch uses O(k log(n/k)) space and the
    rank of a returned quantile is, with high probability, within roughly
    O(log(n/k) / k) of the requested rank. Larger k means smaller rank error and
    more memory. Nothing is guaranteed about how far the returned *value* is from
    an exact quantile in value units -- that depends on the data distribution.

    While no compaction has happened yet (few enough values added), every value is
    retained and all queries are exact.

    The source of randomness is supplied by the caller (any object responding to
    +rand+, e.g. Random.new(seed), or a callable), which makes results
    reproducible in tests and lets callers isolate streams. Note that the error
    bounds are probabilistic: a single lucky run with one seed is not a
    deterministic guarantee.

    NaN values are rejected, since they have no defined order and would corrupt
    the sorted levels.

    Example:

        sketch = Containers::KLLSketch.new(200, random: Random.new(42))
        latencies.each { |ms| sketch.add(ms) }
        sketch.quantile(0.99)   # approximate p99 latency
        center.merge(sketch)    # fold a worker's sketch into the center's
=end
class Containers::KLLSketch
  DEFAULT_K = 200
  # A level needs at least 2 items to be compactable.
  MIN_CAPACITY = 2
  # Per the paper, level capacities shrink geometrically towards the top.
  SHRINK_FACTOR = 2.0 / 3.0

  attr_reader :k, :size, :min, :max
  alias_method :length, :size

  # call-seq:
  #     KLLSketch.new(k = 200, random: Random.new) -> new_sketch
  #
  # +k+ is the capacity parameter: it bounds the rank error of quantile/rank
  # answers (smaller error for larger k), not the error in value units.
  #
  # +random+ is the caller-supplied randomness source: anything responding to
  # +rand+ (e.g. Random.new(seed)) or to +call+ (e.g. a lambda taking the
  # exclusive upper bound). Pass a seeded Random to get reproducible results.
  def initialize(k = DEFAULT_K, random: Random.new)
    unless k.is_a?(Integer) && k >= MIN_CAPACITY
      raise ArgumentError, "k must be an Integer >= #{MIN_CAPACITY}"
    end
    unless random.respond_to?(:rand) || random.respond_to?(:call)
      raise ArgumentError, "random must respond to #rand or #call"
    end
    @k = k
    @random = random
    @levels = [[]] # level 0 (raw values) at the bottom, weight 2**h per level
    @size = 0      # total number of values ever added (sum of weights)
    @min = nil
    @max = nil
  end

  # call-seq:
  #     add(value) -> self
  #
  # Add a value to the sketch. Values must be mutually comparable. NaN is
  # rejected because it has no defined order.
  def add(value)
    if value.respond_to?(:nan?) && value.nan?
      raise ArgumentError, "NaN cannot be added to a KLLSketch"
    end
    @levels[0] << value
    @size += 1
    @min = value if @min.nil? || (value <=> @min) < 0
    @max = value if @max.nil? || (value <=> @max) > 0
    compress if @levels[0].size > capacity(0)
    self
  end
  alias_method :update, :add
  alias_method :push, :add
  alias_method :<<, :add

  # call-seq:
  #     merge(other) -> self
  #
  # Merge +other+ (another KLLSketch, possibly of a different size or capacity)
  # into this one. The result answers queries over the union of both streams
  # and keeps this sketch's capacity parameter. +other+ is left unmodified.
  def merge(other)
    unless other.is_a?(Containers::KLLSketch)
      raise ArgumentError, "can only merge another KLLSketch"
    end
    return self if other.size.zero?

    incoming = other.send(:levels).map(&:dup) # dup also makes self-merge safe
    @levels << [] while @levels.size < incoming.size
    incoming.each_with_index { |items, h| @levels[h].concat(items) }
    @size += other.size
    @min = other.min if @min.nil? || (other.min <=> @min) < 0
    @max = other.max if @max.nil? || (other.max <=> @max) > 0
    compress
    self
  end

  # call-seq:
  #     quantile(q) -> value or nil
  #
  # Return the approximate q-quantile for q in [0, 1]: a value whose rank in
  # the stream is about q * (size - 1). quantile(0) and quantile(1) are always
  # the exact min and max. Returns nil when the sketch is empty.
  def quantile(q)
    unless q.is_a?(Numeric) && !(q.respond_to?(:nan?) && q.nan?) && q >= 0 && q <= 1
      raise ArgumentError, "q must be a number in [0, 1]"
    end
    return nil if @size.zero?
    return @min if q.zero?
    return @max if q == 1

    target = (q * (@size - 1)).ceil
    each_weighted do |value, _weight, cumulative|
      return value if cumulative > target
    end
    @max
  end

  # call-seq:
  #     rank(value) -> int
  #
  # Return the approximate number of stream values <= +value+ (0 when the
  # sketch is empty). Complement of #quantile: quantile(q) has rank about
  # q * (size - 1).
  def rank(value)
    if value.respond_to?(:nan?) && value.nan?
      raise ArgumentError, "NaN cannot be ranked"
    end
    return 0 if @size.zero?

    total = 0
    @levels.each_with_index do |level, h|
      weight = 1 << h
      level.each { |v| total += weight if (v <=> value) <= 0 }
    end
    total
  end

  def empty?
    @size.zero?
  end

  # Number of values currently retained by the sketch. When this equals #size
  # no compaction has happened yet and all answers are exact.
  def retained
    @levels.sum(&:size)
  end

  protected

  attr_reader :levels

  private

  def capacity(h)
    top = @levels.size - 1
    [(@k * (SHRINK_FACTOR**(top - h))).ceil, MIN_CAPACITY].max
  end

  def random_bit
    source = @random
    bit = source.respond_to?(:rand) ? source.rand(2) : source.call(2)
    bit.to_i.zero? ? 0 : 1
  end

  # Compact any over-full level, bottom-up, promoting survivors one level up.
  def compress
    h = 0
    while h < @levels.size
      if @levels[h].size > capacity(h)
        compact(h)
      else
        h += 1
      end
    end
  end

  # Sort level h, keep a randomly chosen half (random odd/even offset), and
  # promote it to level h + 1. For an odd-sized level one element, chosen
  # randomly between the smallest and largest, stays behind so the promoted
  # half is unbiased.
  def compact(h)
    @levels << [] if h + 1 == @levels.size
    level = @levels[h]
    level.sort!
    leftover = []
    if level.size.odd?
      leftover << (random_bit.zero? ? level.shift : level.pop)
    end
    offset = random_bit
    promoted = []
    i = offset
    while i < level.size
      promoted << level[i]
      i += 2
    end
    @levels[h] = leftover
    @levels[h + 1].concat(promoted)
  end

  # Yield each retained value with its weight and running cumulative weight,
  # in ascending value order.
  def each_weighted
    pairs = []
    @levels.each_with_index do |level, h|
      weight = 1 << h
      level.each { |v| pairs << [v, weight] }
    end
    pairs.sort_by!(&:first)
    cumulative = 0
    pairs.each do |value, weight|
      cumulative += weight
      yield value, weight, cumulative
    end
  end
end

