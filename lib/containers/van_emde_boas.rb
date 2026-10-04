=begin rdoc
    A VanEmdeBoasSet is an ordered set of non-negative integers in the fixed
    universe 0..(2**bits - 1). Insertion, deletion, membership, minimum,
    maximum, predecessor, and successor all take O(log bits) time.

    Clusters and summaries are allocated lazily with hashes, so constructing a
    set for a very large universe does not allocate an array of 2**bits nodes.
=end
class Containers::VanEmdeBoasSet
  class Node # :nodoc: all
    attr_reader :min, :max, :bits

    def initialize(bits)
      @bits = bits
      @min = nil
      @max = nil
      @clusters = {}
      @summary = nil
    end

    def empty?
      @min.nil?
    end

    def insert(key)
      if empty?
        @min = @max = key
        return true
      end

      return false if @min == key || @max == key
      inserted = true

      if key < @min
        key, @min = @min, key
      end

      if @bits > 1
        high = key >> low_bits
        low = key & ((1 << low_bits) - 1)
        cluster = @clusters[high]

        if cluster.nil?
          cluster = Node.new(cluster_bits)
          @clusters[high] = cluster
        end

        if cluster.empty?
          ensure_summary.insert(high)
        elsif cluster.member?(low)
          inserted = false
        end

        cluster.insert(low) if inserted
      end

      @max = key if key > @max
      inserted
    end

    def delete(key)
      return nil unless member?(key)
      removed_key = key

      if @min == @max
        clear
        return removed_key
      end

      if @bits == 1
        remaining = key == 0 ? 1 : 0
        @min = @max = remaining
        return removed_key
      end

      if key == @min
        first_cluster = @summary.min
        first_key = @clusters[first_cluster].min
        key = (first_cluster << low_bits) + first_key
        @min = key
      end

      high = key >> low_bits
      low = key & ((1 << low_bits) - 1)
      cluster = @clusters[high]
      cluster.delete(low)

      if cluster.empty?
        @clusters.delete(high)
        @summary.delete(high)
        @summary = nil if @summary.empty?
      end

      if key == @max
        if @summary.nil? || @summary.empty?
          @max = @min
        else
          last_cluster = @summary.max
          @max = (last_cluster << low_bits) + @clusters[last_cluster].max
        end
      end

      removed_key
    end

    def member?(key)
      return true if @min == key || @max == key
      return false if @bits == 1

      cluster = @clusters[key >> low_bits]
      !cluster.nil? && cluster.member?(key & ((1 << low_bits) - 1))
    end

    def predecessor(key)
      return nil if empty? || key <= @min

      if @bits == 1
        return @min == 0 ? 0 : nil
      end

      high = key >> low_bits
      low = key & ((1 << low_bits) - 1)
      cluster = @clusters[high]

      if !cluster.nil? && low > cluster.min
        low_predecessor = cluster.predecessor(low)
        return (high << low_bits) + low_predecessor unless low_predecessor.nil?
      end

      previous_cluster = @summary.nil? ? nil : @summary.predecessor(high)
      return @min if previous_cluster.nil? && @min < key
      return nil if previous_cluster.nil?

      (previous_cluster << low_bits) + @clusters[previous_cluster].max
    end

    def successor(key)
      return nil if empty?
      return @min if key < @min

      if @bits == 1
        return @max == 1 && key == 0 ? 1 : nil
      end

      high = key >> low_bits
      low = key & ((1 << low_bits) - 1)
      cluster = @clusters[high]

      if !cluster.nil? && low < cluster.max
        low_successor = cluster.successor(low)
        return (high << low_bits) + low_successor unless low_successor.nil?
      end

      next_cluster = @summary.nil? ? nil : @summary.successor(high)
      return nil if next_cluster.nil?

      (next_cluster << low_bits) + @clusters[next_cluster].min
    end

    def node_count
      count = 1
      count += @summary.node_count unless @summary.nil?
      @clusters.each_value { |cluster| count += cluster.node_count }
      count
    end

    private

    def clear
      @min = @max = nil
      @clusters.clear
      @summary = nil
    end

    def ensure_summary
      @summary ||= Node.new(summary_bits)
    end

    def summary_bits
      @bits - cluster_bits
    end

    def cluster_bits
      @bits / 2
    end

    def low_bits
      cluster_bits
    end
  end

  # Create a new empty set over the universe 0..(2**bits - 1).
  #
  #   set = Containers::VanEmdeBoasSet.new(8)
  def initialize(bits)
    unless bits.is_a?(Integer) && bits > 0
      raise ArgumentError, "bits must be a positive Integer"
    end

    @bits = bits
    @root = Node.new(bits)
    @size = 0
  end

  # Inserts an integer. Inserting a duplicate leaves the set unchanged.
  # Returns the set.
  def insert(key)
    validate_key!(key)
    @size += 1 if @root.insert(key)
    self
  end
  alias_method :push, :insert
  alias_method :<<, :insert
  alias_method :add, :insert

  # Removes and returns an integer, or nil if it is not in the set.
  def delete(key)
    validate_key!(key)
    deleted = @root.delete(key)
    @size -= 1 unless deleted.nil?
    deleted
  end
  alias_method :remove, :delete

  # Returns true if the integer is in the set.
  def member?(key)
    valid_key?(key) && @root.member?(key)
  end
  alias_method :include?, :member?
  alias_method :has_key?, :member?

  # Returns the smallest integer in the set, or nil if empty.
  def min
    @root.min
  end

  # Returns the largest integer in the set, or nil if empty.
  def max
    @root.max
  end

  # Returns the largest member smaller than key, or nil.
  def predecessor(key)
    validate_key!(key)
    @root.predecessor(key)
  end
  alias_method :prev, :predecessor

  # Returns the smallest member larger than key, or nil.
  def successor(key)
    validate_key!(key)
    @root.successor(key)
  end
  alias_method :next, :successor
  alias_method :succ, :successor

  # Returns the number of distinct integers in the set.
  def size
    @size
  end
  alias_method :length, :size

  # Returns true if the set contains no integers.
  def empty?
    @size.zero?
  end

  # Returns the number of allocated van Emde Boas nodes. This is useful for
  # verifying that clusters are allocated sparsely.
  def node_count
    @root.node_count
  end

  private

  def valid_key?(key)
    key.is_a?(Integer) && key >= 0 && key.bit_length <= @bits
  end

  def validate_key!(key)
    unless valid_key?(key)
      raise ArgumentError, "key must be an Integer in 0..#{(1 << @bits) - 1}"
    end
  end
end

Containers::VanEmdeBoas = Containers::VanEmdeBoasSet
Containers::VanEmdeBoasTree = Containers::VanEmdeBoasSet
