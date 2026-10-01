=begin rdoc
  A Wavelet Tree is a static index over an integer array that answers
  range queries in O(log m) time, where m is the number of distinct
  values (the value range), without re-sorting or copying the data
  per query.

  Supported queries, all over the half-open interval [l, r):

    tree = Containers::WaveletTree.new([3, -1, 3, 2])
    tree.kth(1, 4, 2)              #=> 2   (2nd smallest of [-1, 3, 2])
    tree.count(1, 4, 3)            #=> 1   (occurrences of 3)
    tree.count_less_than(1, 4, 3)  #=> 2   (elements < 3)

  Space usage is O(n log m) integers of bookkeeping (one prefix-count
  array per tree level), not O(n * m) per-value prefix arrays.

  Ranges are half-open: l inclusive, r exclusive. An empty or
  out-of-bounds range raises ArgumentError, while an out-of-range k
  on a valid range returns nil, so the two cases are distinguishable.
=end
class Containers::WaveletTree
  Node = Struct.new(:lo, :hi, :left, :right, :b)

  def initialize(array)
    raise ArgumentError, "cannot index an empty array" if array.empty?
    @n = array.size
    @root = build(array, array.min, array.max)
  end

  # Number of indexed elements.
  attr_reader :n

  # The (1-based) k-th smallest element in the half-open range [l, r).
  # Returns nil when k is out of range for the interval.
  def kth(l, r, k)
    check_range!(l, r)
    return nil if k < 1 || k > r - l
    kth_node(@root, l, r, k)
  end

  # Number of occurrences of +value+ in the half-open range [l, r).
  def count(l, r, value)
    check_range!(l, r)
    count_less_than_node(@root, l, r, value + 1) -
      count_less_than_node(@root, l, r, value)
  end

  # Number of elements strictly less than +x+ in the half-open range [l, r).
  def count_less_than(l, r, x)
    check_range!(l, r)
    count_less_than_node(@root, l, r, x)
  end

  # Total number of integers stored in the index's prefix-count arrays.
  # Grows as O(n log m) with n elements and value range size m.
  def index_size
    stack = [@root]
    total = 0
    until stack.empty?
      node = stack.pop
      total += node.b.size
      stack << node.left if node.left
      stack << node.right if node.right
    end
    total
  end

  private

  def check_range!(l, r)
    unless l.is_a?(Integer) && r.is_a?(Integer) && 0 <= l && l < r && r <= @n
      raise ArgumentError, "invalid or empty range [#{l}, #{r}) for #{@n} elements"
    end
  end

  def build(values, lo, hi)
    node = Node.new(lo, hi)
    if lo == hi
      node.b = Array.new(values.size + 1, 0)
      return node
    end
    mid = lo + (hi - lo) / 2
    b = [0]
    left_values = []
    right_values = []
    values.each do |v|
      if v <= mid
        left_values << v
        b << b.last + 1
      else
        right_values << v
        b << b.last
      end
    end
    node.b = b
    node.left = build(left_values, lo, mid) unless left_values.empty?
    node.right = build(right_values, mid + 1, hi) unless right_values.empty?
    node
  end

  def kth_node(node, l, r, k)
    return node.lo if node.lo == node.hi
    li = node.b[l]
    ri = node.b[r]
    in_left = ri - li
    if k <= in_left
      kth_node(node.left, li, ri, k)
    else
      kth_node(node.right, l - li, r - ri, k - in_left)
    end
  end

  def count_less_than_node(node, l, r, x)
    return 0 if l >= r || x <= node.lo
    return r - l if x > node.hi
    li = node.b[l]
    ri = node.b[r]
    count_less_than_node(node.left, li, ri, x) +
      count_less_than_node(node.right, l - li, r - ri, x)
  end
end
