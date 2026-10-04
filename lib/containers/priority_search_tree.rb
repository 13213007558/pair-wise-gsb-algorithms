=begin rdoc

    A priority search tree stores 2D points and answers three-sided range
    queries of the form "all points with xmin <= x <= xmax and y <= ylimit"
    in O(log n + k) expected time, where k is the number of hits reported.

    The tree is a Cartesian tree over the points: a binary search tree
    ordered by (x, id) that is simultaneously a min-heap ordered by (y, id).
    Consequently the point stored at every node carries the minimum y of its
    whole subtree, and a query can prune any subtree whose minimum y already
    exceeds ylimit. The y bound therefore cuts off branches while descending
    the tree, instead of first collecting the whole x band and filtering on
    y afterwards.

    Points with identical coordinates are allowed as long as their ids
    differ. Example:

      tree = Containers::PrioritySearchTree.new
      tree.insert(1, 10, 5)
      tree.insert(2, 20, 3)
      tree.insert(3, 20, 8)   # same x as point 2, different id

      tree.search(0, 15, 6)                        # => [[1, 10, 5]]
      tree.each_hit(0, 30, 5) { |id, x, y| ... }   # hits one by one
      tree.delete(2)

    After each query, last_visited reports how many nodes were examined,
    which makes the pruning directly observable.

=end

class Containers::PrioritySearchTree
  Node = Struct.new(:id, :x, :y, :left, :right)

  attr_reader :size

  # Number of nodes examined by the most recent query.
  attr_reader :last_visited

  def initialize
    @root = nil
    @size = 0
    @points = {}
    @last_visited = 0
  end

  def empty?
    @size == 0
  end

  def has_key?(id)
    @points.has_key?(id)
  end

  # Insert the point (x, y) under +id+. Ids must be unique; coordinates may
  # repeat freely.
  def insert(id, x, y)
    raise ArgumentError, "duplicate id: #{id.inspect}" if @points.has_key?(id)

    node = Node.new(id, x, y)
    @root = insert_node(@root, node)
    @points[id] = node
    @size += 1
    self
  end

  # Remove the point stored under +id+ and return it as an [id, x, y]
  # triple, or nil if no such id exists.
  def delete(id)
    node = @points[id]
    return nil unless node

    @root = delete_node(@root, node.x, id)
    @points.delete(id)
    @size -= 1
    [node.id, node.x, node.y]
  end

  # Yield every point with xmin <= x <= xmax and y <= ylimit, one at a time.
  # Returns an Enumerator when no block is given.
  def each_hit(xmin, xmax, ylimit)
    return enum_for(:each_hit, xmin, xmax, ylimit) unless block_given?

    @last_visited = 0
    query(@root, xmin, xmax, ylimit) { |point| yield point }
    self
  end

  # All hits of the three-sided query, as an array of [id, x, y] triples.
  def search(xmin, xmax, ylimit)
    each_hit(xmin, xmax, ylimit).to_a
  end

  private

  # Binary-search-tree order on (x, id).
  def compare_keys(x1, id1, x2, id2)
    cmp = x1 <=> x2
    cmp.zero? ? id1 <=> id2 : cmp
  end

  # Min-heap order on (y, id): a sits above b when its y is smaller, with
  # ties broken by id so the tree shape stays deterministic.
  def higher_priority?(a, b)
    cmp = a.y <=> b.y
    cmp.zero? ? (a.id <=> b.id) < 0 : cmp < 0
  end

  def insert_node(root, node)
    return node if root.nil?

    if compare_keys(node.x, node.id, root.x, root.id) < 0
      root.left = insert_node(root.left, node)
      root = rotate_right(root) if higher_priority?(root.left, root)
    else
      root.right = insert_node(root.right, node)
      root = rotate_left(root) if higher_priority?(root.right, root)
    end
    root
  end

  def delete_node(root, x, id)
    return nil if root.nil?

    cmp = compare_keys(x, id, root.x, root.id)
    if cmp < 0
      root.left = delete_node(root.left, x, id)
    elsif cmp > 0
      root.right = delete_node(root.right, x, id)
    else
      return root.right if root.left.nil?
      return root.left if root.right.nil?

      # The node being removed carries its subtree's minimum y, so the child
      # with the next-smallest (y, id) is rotated up in its place; the
      # removed node is pushed further down until it becomes a leaf.
      if higher_priority?(root.left, root.right)
        root = rotate_right(root)
        root.right = delete_node(root.right, x, id)
      else
        root = rotate_left(root)
        root.left = delete_node(root.left, x, id)
      end
    end
    root
  end

  def rotate_left(root)
    pivot = root.right
    root.right = pivot.left
    pivot.left = root
    pivot
  end

  def rotate_right(root)
    pivot = root.left
    root.left = pivot.right
    pivot.right = root
    pivot
  end

  def query(node, xmin, xmax, ylimit)
    return if node.nil?

    @last_visited += 1
    # Heap order on y: every descendant has y >= node.y, so once node.y
    # exceeds ylimit the whole subtree can be skipped.
    return if node.y > ylimit

    yield [node.id, node.x, node.y] if node.x >= xmin && node.x <= xmax
    query(node.left, xmin, xmax, ylimit) { |point| yield point } if node.left && xmin <= node.x
    query(node.right, xmin, xmax, ylimit) { |point| yield point } if node.right && node.x <= xmax
  end
end
