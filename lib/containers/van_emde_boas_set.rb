=begin rdoc
  A van Emde Boas ordered set for non-negative integers in the fixed universe
  0..(2**bits - 1). It supports insert, delete, membership, minimum/maximum,
  predecessor, and successor operations in O(log bits) time.

  Unlike a direct-indexed implementation, clusters and summaries are created
  lazily and empty clusters are released on delete, so an empty 1024-bit set
  uses one node rather than allocating proportional to 2**1024.
=end
class Containers::VanEmdeBoasSet
  class Node # :nodoc: all
    attr_reader :min, :max, :bits

    def initialize(bits)
      @bits = bits
      @min = nil
      @max = nil

      unless bits == 1
        @lower_bits = bits / 2
        @lower_size = 1 << @lower_bits
        @upper_bits = bits - @lower_bits
        @summary = nil
        @clusters = {}
      end
    end

    def empty?
      @min.nil?
    end

    def insert(key)
      return false if key == @min || key == @max

      if @min.nil?
        @min = key
        @max = key
        return true
      end

      if @bits == 1
        @min = key if key < @min
        @max = key if key > @max
        return true
      end

      if key < @min
        key, @min = @min, key
      end
      @max = key if key > @max

      high = key / @lower_size
      low = key % @lower_size
      cluster = @clusters[high]

      if cluster.nil?
        cluster = Node.new(@lower_bits)
        @clusters[high] = cluster
        @summary ||= Node.new(@upper_bits)
        @summary.insert(high)
      end

      cluster.insert(low)
    end

    def delete(key)
      return false unless member?(key)

      if @bits == 1
        if key == @min
          if @min == @max
            @min = nil
            @max = nil
          else
            @min = @max
          end
        else
          @max = @min
        end
        return true
      end

      if key == @min
        if @summary.nil?
          @min = nil
          @max = nil
          return true
        end

        high = @summary.min
        cluster = @clusters[high]
        low = cluster.min
        key = high * @lower_size + low
        @min = key
      end

      high = key / @lower_size
      low = key % @lower_size
      cluster = @clusters[high]
      cluster.delete(low)

      if cluster.empty?
        @clusters.delete(high)
        @summary.delete(high)
        @summary = nil if @summary.empty?
      end

      if key == @max
        if @summary.nil?
          @max = @min
        else
          high = @summary.max
          @max = high * @lower_size + @clusters[high].max
        end
      end

      true
    end

    def member?(key)
      return false if @min.nil?
      return true if key == @min || key == @max
      return false if @bits == 1

      cluster = @clusters[key / @lower_size]
      !cluster.nil? && cluster.member?(key % @lower_size)
    end

    def predecessor(key)
      return nil if @min.nil?
      return @max if key > @max

      if @bits == 1
        return @min if key == 1 && @min == 0
        return nil
      end

      high = key / @lower_size
      low = key % @lower_size
      cluster = @clusters[high]

      unless cluster.nil?
        predecessor = cluster.predecessor(low)
        return high * @lower_size + predecessor unless predecessor.nil?
      end

      unless @summary.nil?
        previous_cluster = @summary.predecessor(high)
        unless previous_cluster.nil?
          return previous_cluster * @lower_size + @clusters[previous_cluster].max
        end
      end

      @min if key > @min
    end

    def successor(key)
      return nil if @min.nil?
      return @min if key < @min

      if @bits == 1
        return @max if key == 0 && @max == 1
        return nil
      end

      high = key / @lower_size
      low = key % @lower_size
      cluster = @clusters[high]

      unless cluster.nil?
        successor = cluster.successor(low)
        return high * @lower_size + successor unless successor.nil?
      end

      unless @summary.nil?
        next_cluster = @summary.successor(high)
        unless next_cluster.nil?
          return next_cluster * @lower_size + @clusters[next_cluster].min
        end
      end

      @max if key < @max
    end

    def node_count
      count = 1
      if @bits > 1
        count += @summary.node_count unless @summary.nil?
        @clusters.each_value { |cluster| count += cluster.node_count }
      end
      count
    end
  end

  attr_reader :size, :bits

  # Create an empty ordered set over the universe 0..(2**bits - 1).
  #
  # Clusters and summaries are allocated lazily, so construction does not
  # allocate an array proportional to the universe size.
  #
  # Complexity: O(bits) for key range setup
  def initialize(bits)
    unless bits.is_a?(Integer) && bits >= 1
      raise ArgumentError, "bits must be a positive Integer"
    end

    @bits = bits
    @root = Node.new(bits)
    @size = 0
    @max_key = (1 << bits) - 1
  end

  # Insert an integer key. Returns the key, or nil if it was already present.
  #
  # Complexity: O(log bits)
  def insert(key)
    validate_key!(key)
    if @root.insert(key)
      @size += 1
      key
    end
  end
  alias_method :<<, :insert

  # Delete an integer key. Returns the key, or nil if it was not present.
  #
  # Complexity: O(log bits)
  def delete(key)
    validate_key!(key)
    if @root.delete(key)
      @size -= 1
      key
    end
  end

  # Return true if key is present.
  #
  # Complexity: O(log bits)
  def include?(key)
    validate_key!(key)
    @root.member?(key)
  end
  alias_method :member?, :include?

  # Return true if the set contains no keys.
  def empty?
    @size.zero?
  end

  # Return the smallest key, or nil if the set is empty.
  def min
    @root.min
  end

  # Return the largest key, or nil if the set is empty.
  def max
    @root.max
  end

  # Return the largest stored key strictly smaller than key, or nil.
  #
  # Complexity: O(log bits)
  def predecessor(key)
    validate_key!(key)
    @root.predecessor(key)
  end

  # Return the smallest stored key strictly larger than key, or nil.
  #
  # Complexity: O(log bits)
  def successor(key)
    validate_key!(key)
    @root.successor(key)
  end

  # Return the number of lazily allocated vEB nodes.
  def node_count
    @root.node_count
  end

  private

  def validate_key!(key)
    unless key.is_a?(Integer) && key >= 0 && key <= @max_key
      raise ArgumentError, "key must be an Integer in 0..#{@max_key}"
    end
  end
end
