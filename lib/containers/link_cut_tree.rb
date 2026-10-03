=begin rdoc
    A Link-Cut Tree maintains a forest of rooted trees under dynamic
    link (add edge) and cut (remove edge) operations, and supports
    aggregate queries and updates on the path between any two nodes.

    This implementation uses splay trees with lazy propagation to achieve
    O(log n) amortized time per operation. Path aggregates supported are
    sum (query) and add (range update on a path).

    Node objects are created with Containers::LinkCutTree#make_node and
    keep their object identity across link/cut/make_root operations, so
    external references to nodes remain valid at all times.

    Example:

      tree = Containers::LinkCutTree.new
      a = tree.make_node(1)
      b = tree.make_node(2)
      tree.link(a, b)
      tree.connected?(a, b)   #=> true
      tree.path_sum(a, b)     #=> 3
      tree.path_add(a, b, 10)
      tree.path_sum(a, b)     #=> 23
      tree.cut(a, b)
      tree.connected?(a, b)   #=> false
=end
class Containers::LinkCutTree
  # A node of the forest. Nodes are created via LinkCutTree#make_node and
  # are never copied or replaced, so object identity is stable across all
  # structural operations (link, cut, make_root).
  class Node
    # The value carried by this node. Note that lazy path updates
    # (LinkCutTree#path_add) may leave this stale; use
    # LinkCutTree#get_value for a guaranteed consistent read, and
    # LinkCutTree#set_value to change it.
    attr_reader :value

    # Internal splay-tree state. Not part of the public API.
    attr_accessor :left, :right, :parent, :rev, :pending_add, :sum, :size

    def initialize(value)
      @value = value
      @sum = value
      @size = 1
      @pending_add = 0
      @rev = false
      @left = @right = @parent = nil
    end

    # Internal: used by LinkCutTree to update the stored value.
    def value=(new_value)
      @value = new_value
    end
  end

  # call-seq:
  #     LinkCutTree.new -> new_tree
  #
  # Returns an empty forest. Add nodes with #make_node.
  def initialize
    @size = 0
  end

  # The number of nodes created through this tree.
  attr_reader :size

  # call-seq:
  #     make_node(value = 0) -> node
  #
  # Creates a new isolated node carrying +value+ and returns it. The
  # returned object identity is stable for the lifetime of the node.
  #
  # Complexity: O(log n) amortized for all structural operations below.
  def make_node(value = 0)
    @size += 1
    Node.new(value)
  end

  # call-seq:
  #     make_root(node) -> node
  #
  # Makes +node+ the root of its represented tree.
  def make_root(node)
    access(node)
    apply_rev(node)
    node
  end

  # call-seq:
  #     connected?(a, b) -> true or false
  #
  # Returns true if +a+ and +b+ belong to the same tree.
  def connected?(a, b)
    return true if a.equal?(b)
    find_root(a).equal?(find_root(b))
  end

  # call-seq:
  #     link(child, parent) -> true
  #
  # Adds an edge between +child+ and +parent+, making +child+ a child of
  # +parent+ in the represented forest. Raises ArgumentError if the two
  # nodes are already connected, since the edge would create a cycle.
  def link(child, parent)
    raise ArgumentError, "link would create a cycle: nodes are already connected" if connected?(child, parent)
    make_root(child)
    child.parent = parent
    true
  end

  # call-seq:
  #     cut(a, b) -> true
  #
  # Removes the edge directly connecting +a+ and +b+. Raises ArgumentError
  # if no such edge exists.
  def cut(a, b)
    make_root(a)
    access(b)
    # After make_root(a) and access(b), the edge (a, b) exists iff a is
    # the left child of b and a has no right child (they are adjacent on
    # the preferred path with nothing in between).
    unless b.left.equal?(a) && a.right.nil?
      raise ArgumentError, "cannot cut: no edge between the given nodes"
    end
    b.left = nil
    a.parent = nil
    pull(b)
    true
  end

  # call-seq:
  #     path_sum(a, b) -> number
  #
  # Returns the sum of the values of the nodes on the path between +a+
  # and +b+ (inclusive). The nodes must be connected.
  def path_sum(a, b)
    expose_path(a, b)
    b.sum
  end

  # call-seq:
  #     path_add(a, b, delta) -> true
  #
  # Adds +delta+ to the value of every node on the path between +a+ and
  # +b+ (inclusive). The nodes must be connected.
  def path_add(a, b, delta)
    expose_path(a, b)
    apply_add(b, delta)
    true
  end

  # call-seq:
  #     get_value(node) -> value
  #
  # Returns the current value of a single node, flushing any pending
  # lazy path updates that cover it.
  #
  # Complexity: O(log n) amortized
  def get_value(node)
    access(node)
    node.value
  end

  # call-seq:
  #     set_value(node, value) -> value
  #
  # Sets the value of a single node, keeping path aggregates consistent.
  def set_value(node, value)
    access(node)
    node.value = value
    pull(node)
    value
  end

  private

  # Makes the path between +a+ and +b+ the preferred path and splays +b+,
  # so that +b+'s splay subtree contains exactly the nodes on the path.
  def expose_path(a, b)
    make_root(a)
    access(b)
  end

  def splay_root?(node)
    parent = node.parent
    parent.nil? || (!parent.left.equal?(node) && !parent.right.equal?(node))
  end

  def pull(node)
    sum = node.value
    size = 1
    if (left = node.left)
      sum += left.sum
      size += left.size
    end
    if (right = node.right)
      sum += right.sum
      size += right.size
    end
    node.sum = sum
    node.size = size
    node
  end

  def apply_rev(node)
    node.left, node.right = node.right, node.left
    node.rev = !node.rev
    node
  end

  def apply_add(node, delta)
    node.value = node.value + delta
    node.pending_add += delta
    node.sum += delta * node.size
    node
  end

  def push(node)
    if node.rev
      apply_rev(node.left) if node.left
      apply_rev(node.right) if node.right
      node.rev = false
    end
    if node.pending_add != 0
      delta = node.pending_add
      apply_add(node.left, delta) if node.left
      apply_add(node.right, delta) if node.right
      node.pending_add = 0
    end
    node
  end

  def rotate(node)
    parent = node.parent
    grand = parent.parent
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
    node.parent = grand
    if grand
      if grand.left.equal?(parent)
        grand.left = node
      elsif grand.right.equal?(parent)
        grand.right = node
      end
    end
    pull(parent)
    pull(node)
    node
  end

  def splay(node)
    # Push down lazy flags from the top of the splay tree to +node+.
    stack = []
    current = node
    loop do
      stack << current
      break if splay_root?(current)
      current = current.parent
    end
    stack.reverse_each { |ancestor| push(ancestor) }

    until splay_root?(node)
      parent = node.parent
      grand = parent.parent
      unless splay_root?(parent)
        if parent.left.equal?(node) == grand.left.equal?(parent)
          rotate(parent) # zig-zig
        else
          rotate(node)   # zig-zag
        end
      end
      rotate(node)
    end
    pull(node)
    node
  end

  def access(node)
    last = nil
    current = node
    until current.nil?
      splay(current)
      current.right = last
      pull(current)
      last = current
      current = current.parent
    end
    splay(node)
    last
  end

  def find_root(node)
    access(node)
    current = node
    push(current)
    while current.left
      current = current.left
      push(current)
    end
    splay(current)
    current
  end
end
