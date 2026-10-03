=begin rdoc
    A LinkCutTree maintains a dynamic forest while supporting path queries and
    updates in amortized O(log n) time per operation.

    Node objects are stable across link, cut, and make_root operations; only the
    internal pointers used by the data structure change.
=end
class Containers::LinkCutTree
  class Node
    attr_accessor :left, :right, :parent, :reversed, :lazy_add, :size, :sum
    attr_accessor :raw_value
    attr_reader :tree

    def initialize(tree, value = 0)
      @tree = tree
      @raw_value = value
      @sum = value
      @size = 1
      @left = nil
      @right = nil
      @parent = nil
      @reversed = false
      @lazy_add = 0
    end

    # Return the node's current value after applying any pending path updates.
    def value
      @tree.node_value(self)
    end

    # Set the node's value without changing its position in the forest.
    def value=(value)
      @tree.set_value(self, value)
    end
  end

  def initialize
    @nodes = []
  end

  # Add a disconnected node with +value+ and return the stable Node object.
  def add_node(value = 0)
    assert_numeric(value)
    node = Node.new(self, value)
    @nodes << node
    node
  end

  # Return the number of nodes ever added to this forest.
  def size
    @nodes.size
  end

  # Make +node+ the root of its represented tree. Returns the node.
  def make_root(node)
    node = validate_node!(node, :node)
    access(node)
    apply_reverse(node)
    node
  end

  # Return true when +a+ and +b+ belong to the same represented tree.
  def connected?(a, b)
    a = validate_node!(a, :a)
    b = validate_node!(b, :b)
    find_root(a).equal?(find_root(b))
  end

  # Link two disconnected nodes. Returns false when the link would create a cycle.
  def link(a, b)
    a = validate_node!(a, :a)
    b = validate_node!(b, :b)
    return false if a.equal?(b) || connected?(a, b)

    make_root(a)
    a.parent = b
    true
  end

  # Cut the edge directly joining +a+ and +b+. Returns false when no such edge exists.
  def cut(a, b)
    a = validate_node!(a, :a)
    b = validate_node!(b, :b)
    return false if a.equal?(b)

    make_root(a)
    access(b)
    push(b)
    return false unless b.left.equal?(a) && a.right.nil?

    b.left = nil
    a.parent = nil
    aggregate(b)
    true
  end

  # Return the sum of values on the path from +a+ to +b+, or nil if disconnected.
  def path_sum(a, b)
    exposed = expose_path(a, b)
    exposed ? exposed.sum : nil
  end

  # Add +delta+ to every node on the path from +a+ to +b+. Returns the new path
  # sum, or nil if the nodes are disconnected.
  def add_path(a, b, delta)
    assert_numeric(delta)
    exposed = expose_path(a, b)
    return nil unless exposed

    apply_add(exposed, delta)
    exposed.sum
  end
  alias_method :path_add, :add_path
  alias_method :update_path, :add_path

  # Return a node's current materialized value.
  def node_value(node)
    node = validate_node!(node, :node)
    access(node)
    node.raw_value
  end

  # Set a node's value without changing its position in the forest.
  def set_value(node, value)
    node = validate_node!(node, :node)
    assert_numeric(value)
    access(node)
    node.raw_value = value
    aggregate(node)
    value
  end

  private

  def validate_node!(node, name)
    return node if node.is_a?(Node) && node.tree.equal?(self)
    raise ArgumentError, "#{name} must belong to this LinkCutTree"
  end

  def assert_numeric(value)
    return if value.is_a?(Numeric)
    raise ArgumentError, "value must be Numeric"
  end

  def auxiliary_root?(node)
    parent = node.parent
    parent.nil? || (parent.left != node && parent.right != node)
  end

  def apply_reverse(node)
    return unless node

    node.left, node.right = node.right, node.left
    node.reversed = !node.reversed
  end

  def apply_add(node, delta)
    return unless node

    node.raw_value += delta
    node.sum += delta * node.size
    node.lazy_add += delta
  end

  def push(node)
    return unless node

    if node.reversed
      apply_reverse(node.left)
      apply_reverse(node.right)
      node.reversed = false
    end

    unless node.lazy_add.zero?
      apply_add(node.left, node.lazy_add)
      apply_add(node.right, node.lazy_add)
      node.lazy_add = 0
    end
  end

  def aggregate(node)
    node.size = 1
    node.sum = node.raw_value

    if node.left
      node.size += node.left.size
      node.sum += node.left.sum
    end

    if node.right
      node.size += node.right.size
      node.sum += node.right.sum
    end

    node
  end

  def rotate(node)
    parent = node.parent
    grandparent = parent.parent
    push(parent)
    push(node)

    if parent.left.equal?(node)
      parent.left = node.right
      node.right.parent = parent if node.right
      node.right = parent
    else
      parent.right = node.left
      node.left.parent = parent if node.left
      node.left = parent
    end

    parent.parent = node
    node.parent = grandparent
    if grandparent
      if grandparent.left.equal?(parent)
        grandparent.left = node
      elsif grandparent.right.equal?(parent)
        grandparent.right = node
      end
    end

    aggregate(parent)
    aggregate(node)
  end

  def splay(node)
    ancestors = []
    cursor = node
    until auxiliary_root?(cursor)
      ancestors << cursor
      cursor = cursor.parent
    end
    ancestors << cursor
    ancestors.reverse_each { |ancestor| push(ancestor) }

    until auxiliary_root?(node)
      parent = node.parent
      grandparent = parent.parent

      unless auxiliary_root?(parent)
        if grandparent.left.equal?(parent) == parent.left.equal?(node)
          rotate(parent)
        else
          rotate(node)
        end
      end

      rotate(node)
    end

    aggregate(node)
  end

  def access(node)
    last = nil
    cursor = node

    while cursor
      splay(cursor)
      cursor.right = last
      last.parent = cursor if last
      aggregate(cursor)
      last = cursor
      cursor = cursor.parent
    end

    splay(node)
    node
  end

  def find_root(node)
    access(node)
    while node.left
      push(node)
      node = node.left
    end
    splay(node)
    node
  end

  def expose_path(a, b)
    a = validate_node!(a, :a)
    b = validate_node!(b, :b)
    return nil unless find_root(a).equal?(find_root(b))

    make_root(a)
    access(b)
    b
  end
end
