=begin rdoc

    A priority search tree stores two-dimensional points and answers three-sided
    range queries of the form:

      xmin <= x <= xmax AND y <= limit

    Points are ordered by x and insertion order in an AVL tree, while every
    node caches the smallest y in its subtree. That cached value lets a query
    skip an entire subtree whenever its smallest y is already above the query's
    y limit.

    Multiple points may have the same coordinates as long as their IDs differ.
    Query results are yielded one at a time, or returned as a lazy Enumerator
    when no block is given.

=end

class Containers::PrioritySearchTree
  class Node # :nodoc: all
    attr_accessor :id, :x, :y, :sequence, :left, :right, :height, :min_y

    def initialize(id, x, y, sequence)
      @id = id
      @x = x
      @y = y
      @sequence = sequence
      @left = nil
      @right = nil
      @height = 1
      @min_y = y
    end
  end

  attr_reader :size, :last_query_access_count

  # Create a new priority search tree. An optional Hash of id => [x, y] pairs
  # may be supplied.
  def initialize(points = nil)
    unless points.nil? || points.kind_of?(Hash)
      raise ArgumentError, "must pass in a hash of id => [x, y] pairs"
    end

    @root = nil
    @points = {}
    @sequences = {}
    @size = 0
    @next_sequence = 0
    @last_query_access_count = 0

    points&.each { |id, (x, y)| insert(id, x, y) }
  end

  def empty?
    @size.zero?
  end

  # Insert a point. IDs must be unique, even when several points share the same
  # coordinates. Returns the inserted [x, y] pair.
  #
  # Complexity: O(log n)
  def insert(id, x, y)
    if @points.key?(id)
      raise ArgumentError, "id #{id.inspect} is already in the tree"
    end

    sequence = @next_sequence
    @next_sequence += 1
    @points[id] = [x, y]
    @sequences[id] = sequence
    @root = insert_node(@root, id, x, y, sequence)
    @size += 1
    [x, y]
  end

  # Delete the point with the given ID and return its [x, y] pair. Returns nil
  # when the ID is not present.
  #
  # Complexity: O(log n)
  def delete(id)
    point = @points.delete(id)
    return nil unless point

    x, _y = point
    sequence = @sequences.delete(id)
    @root = delete_node(@root, x, sequence)
    @size -= 1
    point
  end

  # Find points satisfying xmin <= x <= xmax and y <= limit.
  #
  # With a block, yields [id, x, y] for each hit and returns the number of
  # nodes inspected. Without a block, returns a lazy Enumerator. Its
  # access_count method reports the number of inspected nodes after iteration.
  #
  # Results are ordered by x and insertion order. Sparse queries take
  # O(log n + k) time, where k is the number of reported points.
  def query(xmin, xmax, limit)
    raise ArgumentError, "xmin cannot be greater than xmax" if xmin > xmax

    accesses = [0]
    if block_given?
      visit(@root, xmin, xmax, limit, accesses) { |point| yield(point) }
      @last_query_access_count = accesses[0]
    else
      enumerator = Enumerator.new do |yielder|
        accesses[0] = 0
        visit(@root, xmin, xmax, limit, accesses) { |point| yielder.yield(point) }
        @last_query_access_count = accesses[0]
      end
      enumerator.define_singleton_method(:access_count) { accesses[0] }
      enumerator
    end
  end
  alias_method :find_each, :query

  private

  def insert_node(node, id, x, y, sequence)
    return Node.new(id, x, y, sequence) if node.nil?

    comparison = compare_points(x, sequence, node.x, node.sequence)
    if comparison.negative?
      node.left = insert_node(node.left, id, x, y, sequence)
    else
      node.right = insert_node(node.right, id, x, y, sequence)
    end

    rebalance(node)
  end

  def delete_node(node, x, sequence)
    return nil if node.nil?

    comparison = compare_points(x, sequence, node.x, node.sequence)
    if comparison.negative?
      node.left = delete_node(node.left, x, sequence)
    elsif comparison.positive?
      node.right = delete_node(node.right, x, sequence)
    elsif node.left.nil?
      return node.right
    elsif node.right.nil?
      return node.left
    else
      successor = minimum_node(node.right)
      replacement_id = successor.id
      replacement_x = successor.x
      replacement_y = successor.y
      replacement_sequence = successor.sequence
      node.right = delete_node(node.right, replacement_x, replacement_sequence)
      node.id = replacement_id
      node.x = replacement_x
      node.y = replacement_y
      node.sequence = replacement_sequence
    end

    rebalance(node)
  end

  def visit(node, xmin, xmax, limit, accesses)
    return unless node

    accesses[0] += 1
    return if node.min_y > limit

    if node.x < xmin
      visit(node.right, xmin, xmax, limit, accesses) { |point| yield(point) }
    elsif node.x > xmax
      visit(node.left, xmin, xmax, limit, accesses) { |point| yield(point) }
    else
      visit(node.left, xmin, xmax, limit, accesses) { |point| yield(point) }
      yield([node.id, node.x, node.y]) if node.y <= limit
      visit(node.right, xmin, xmax, limit, accesses) { |point| yield(point) }
    end
  end

  def compare_points(x, sequence, other_x, other_sequence)
    comparison = x <=> other_x
    comparison = sequence <=> other_sequence if comparison.zero?
    comparison
  end

  def minimum_node(node)
    node = node.left while node.left
    node
  end

  def rebalance(node)
    refresh(node)
    factor = balance_factor(node)

    if factor > 1
      node.left = rotate_left(node.left) if balance_factor(node.left).negative?
      node = rotate_right(node)
    elsif factor < -1
      node.right = rotate_right(node.right) if balance_factor(node.right).positive?
      node = rotate_left(node)
    end

    node
  end

  def refresh(node)
    node.height = 1 + [height(node.left), height(node.right)].max
    node.min_y = [node.y, min_y(node.left), min_y(node.right)].compact.min
    node
  end

  def rotate_right(node)
    pivot = node.left
    node.left = pivot.right
    pivot.right = node
    refresh(node)
    refresh(pivot)
    pivot
  end

  def rotate_left(node)
    pivot = node.right
    node.right = pivot.left
    pivot.left = node
    refresh(node)
    refresh(pivot)
    pivot
  end

  def balance_factor(node)
    height(node.left) - height(node.right)
  end

  def height(node)
    node.nil? ? 0 : node.height
  end

  def min_y(node)
    node&.min_y
  end
end
