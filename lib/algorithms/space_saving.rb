=begin rdoc
    Space-Saving is a fixed-capacity summary for finding heavy hitters in a stream.

    Each monitored item stores an estimated count and the maximum over-count that
    may have been introduced when that item replaced an earlier candidate. For a
    monitored item +x+, its true frequency is in the range:

        estimate(x) - error(x) <= frequency(x) <= estimate(x)

    An item that is not monitored has frequency no greater than #omission_bound.
=end
class Algorithms::SpaceSaving
  include Enumerable

  Candidate = Struct.new(:item, :count, :error) do
    alias_method :frequency, :count
    alias_method :error_bound, :error
  end

  Entry = Struct.new(:count, :error)
  private_constant :Entry

  attr_reader :capacity, :total, :omission_bound

  # Create an empty Space-Saving summary with a fixed number of candidate slots.
  def initialize(capacity)
    unless capacity.is_a?(Integer) && capacity > 0
      raise ArgumentError, "capacity must be a positive integer"
    end

    @capacity = capacity
    @entries = {}
    @buckets = Hash.new { |hash, count| hash[count] = {} }
    @min_count = 0
    @omission_bound = 0
    @total = 0
  end

  # Observe one event for _item_ and return the summary.
  def update(item)
    @total += 1

    if @entries.key?(item)
      entry = @entries[item]
      move_item(item, entry.count, entry.count + 1)
      entry.count += 1
    elsif full?
      replaced_item = @buckets[@min_count].first.first
      remove_from_bucket(replaced_item, @min_count)
      @entries.delete(replaced_item)

      entry = Entry.new(@min_count + 1, @min_count)
      @entries[item] = entry
      add_to_bucket(item, entry.count)
      @min_count = entry.count unless @buckets.key?(@min_count)
      @omission_bound = @min_count
    else
      entry = Entry.new(1, 0)
      @entries[item] = entry
      add_to_bucket(item, 1)
      @min_count = 1
    end

    self
  end
  alias_method :<<, :update

  # Observe each event in _events_.
  def update_all(events)
    events.each { |item| update(item) }
    self
  end

  # Return the number of monitored candidates.
  def size
    @entries.size
  end
  alias_method :length, :size

  def empty?
    @entries.empty?
  end

  def full?
    @entries.size == @capacity
  end

  def candidate?(item)
    @entries.key?(item)
  end
  alias_method :monitored?, :candidate?

  # Return the estimated upper bound on the frequency of _item_.
  def estimate(item)
    candidate?(item) ? @entries[item].count : @omission_bound
  end
  alias_method :frequency, :estimate

  # Return the maximum possible over-count in the estimate for _item_.
  def error(item)
    candidate?(item) ? @entries[item].error : @omission_bound
  end
  alias_method :error_bound, :error

  # Return [estimated frequency, error bound] for _item_.
  def bounds(item)
    [estimate(item), error(item)]
  end
  alias_method :[], :bounds

  # Return the monitored items, ordered by decreasing estimated frequency.
  def candidates
    to_a.map(&:item)
  end

  # Yield a Candidate for each monitored item, ordered by decreasing estimate.
  def each
    return enum_for unless block_given?

    @buckets.keys.sort.reverse_each do |count|
      @buckets[count].each_key do |item|
        entry = @entries[item]
        yield Candidate.new(item, entry.count, entry.error)
      end
    end
  end

  # Return a new summary containing this summary merged with _other_.
  def merge(other)
    dup.merge!(other)
  end

  # Merge _other_ into this summary. Both summaries must have equal capacity.
  def merge!(other)
    unless other.is_a?(Algorithms::SpaceSaving)
      raise ArgumentError, "can only merge another Space-Saving summary"
    end
    unless other.capacity == @capacity
      raise ArgumentError, "cannot merge summaries with different capacities"
    end

    left_state = candidate_state
    right_state = other.candidate_state
    original_omission_bound = @omission_bound
    combined = {}

    (left_state.keys | right_state.keys).each do |item|
      left_missing_count = missing_count(left_state)
      right_missing_count = other.missing_count(right_state)
      left_count, left_error = left_state.fetch(item, [left_missing_count, left_missing_count])
      right_count, right_error = right_state.fetch(item, [right_missing_count, right_missing_count])
      combined[item] = [left_count + right_count, left_error + right_error]
    end

    retained = combined.sort_by.with_index do |(item, (count, error)), index|
      [-count, error, index]
    end.first(@capacity)

    @entries = {}
    @buckets = Hash.new { |hash, count| hash[count] = {} }
    retained.each do |item, (count, error)|
      @entries[item] = Entry.new(count, error)
      add_to_bucket(item, count)
    end

    @min_count = full? ? @buckets.keys.min : 0
    @omission_bound = full? ? @min_count : original_omission_bound + other.omission_bound
    @total += other.total
    self
  end

  # Merge two summaries with equal capacity without changing either input.
  def self.merge(left, right)
    left.merge(right)
  end

  protected

  def candidate_state
    @entries.each_with_object({}) do |(item, entry), state|
      state[item] = [entry.count, entry.error]
    end
  end

  def missing_count(state)
    state.size == @capacity ? @omission_bound : 0
  end

  private

  def add_to_bucket(item, count)
    @buckets[count][item] = true
  end

  def remove_from_bucket(item, count)
    bucket = @buckets[count]
    bucket.delete(item)
    @buckets.delete(count) if bucket.empty?
  end

  def move_item(item, old_count, new_count)
    remove_from_bucket(item, old_count)
    add_to_bucket(item, new_count)
    @min_count = new_count if old_count == @min_count && !@buckets.key?(old_count)
  end

  def initialize_copy(source)
    super
    @entries = source.candidate_state.each_with_object({}) do |(item, (count, error)), entries|
      entries[item] = Entry.new(count, error)
    end
    @buckets = Hash.new { |hash, count| hash[count] = {} }
    @entries.each_key { |item| add_to_bucket(item, @entries[item].count) }
  end
end
