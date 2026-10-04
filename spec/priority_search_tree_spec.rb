$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::PrioritySearchTree do
  let(:tree) { Containers::PrioritySearchTree.new }

  # Inorder walk: every [id, x, y] point stored in the tree.
  def tree_points(node)
    return [] if node.nil?

    tree_points(node.left) + [[node.id, node.x, node.y]] + tree_points(node.right)
  end

  # The two structural invariants of a priority search tree:
  # a binary search tree on (x, id) and a min-heap on (y, id).
  def expect_valid(tree)
    root = tree.instance_variable_get(:@root)
    points = tree_points(root)
    expect(points.size).to eql(tree.size)
    keys = points.map { |id, x, _y| [x, id] }
    expect(keys).to eql(keys.sort)
    expect_heap_order(root)
  end

  def expect_heap_order(node)
    return if node.nil?

    [node.left, node.right].compact.each do |child|
      expect([child.y, child.id] <=> [node.y, node.id]).to be >= 0
    end
    expect_heap_order(node.left)
    expect_heap_order(node.right)
  end

  def naive_scan(points, xmin, xmax, ylimit)
    points.select { |_id, (x, y)| x >= xmin && x <= xmax && y <= ylimit }
          .map { |id, (x, y)| [id, x, y] }
          .sort
  end

  it "answers xmin <= x <= xmax and y <= ylimit queries" do
    tree.insert(1, 10, 5)
    tree.insert(2, 20, 3)
    tree.insert(3, 20, 8)
    tree.insert(4, 30, 1)

    expect(tree.search(0, 25, 5).sort).to eql([[1, 10, 5], [2, 20, 3]])
    expect(tree.search(20, 20, 8).sort).to eql([[2, 20, 3], [3, 20, 8]])
    expect(tree.search(0, 100, 0)).to eql([])
    expect(tree.size).to eql(4)

    collected = []
    tree.each_hit(0, 100, 100) { |id, x, y| collected << [id, x, y] }
    expect(collected.sort).to eql([[1, 10, 5], [2, 20, 3], [3, 20, 8], [4, 30, 1]])

    expect(tree.delete(2)).to eql([2, 20, 3])
    expect(tree.search(0, 100, 100).sort).to eql([[1, 10, 5], [3, 20, 8], [4, 30, 1]])
    expect(tree.size).to eql(3)
    expect_valid(tree)
  end

  it "handles an empty tree" do
    expect(tree).to be_empty
    expect(tree.search(0, 10, 10)).to eql([])
    expect(tree.last_visited).to eql(0)
    expect(tree.delete(42)).to be_nil
  end

  it "rejects duplicate ids but allows duplicate coordinates" do
    tree.insert(1, 5, 5)
    expect { tree.insert(1, 9, 9) }.to raise_error(ArgumentError)

    tree.insert(2, 5, 5)
    tree.insert(3, 5, 9)
    expect(tree.search(5, 5, 10).sort).to eql([[1, 5, 5], [2, 5, 5], [3, 5, 9]])
    expect(tree.search(5, 5, 5).sort).to eql([[1, 5, 5], [2, 5, 5]])

    tree.delete(2)
    expect(tree.search(5, 5, 10).sort).to eql([[1, 5, 5], [3, 5, 9]])
    expect_valid(tree)
  end

  it "enumerates hits one by one, lazily" do
    rng = Random.new(3)
    1_000.times { |i| tree.insert(i, rng.rand(1_000), rng.rand(1_000)) }

    full = tree.search(0, 1_000, 1_000)
    full_visits = tree.last_visited

    enum = tree.each_hit(0, 1_000, 1_000)
    expect(enum).to be_a(Enumerator)
    expect(enum.first(3).size).to eql(3)
    # only a few nodes were touched to produce the first hits
    expect(tree.last_visited).to be < full_visits / 10
    expect(tree.each_hit(0, 1_000, 1_000).to_a.sort).to eql(full.sort)
  end

  it "prunes subtrees by y instead of scanning the whole x band" do
    rng = Random.new(42)
    n = 10_000
    pts = (0...n).map { |i| [i, rng.rand(n), rng.rand(n)] }
    pts.each { |id, x, y| tree.insert(id, x, y) }

    # sparse hits: a wide x band but a tight y limit
    xmin, xmax, ylimit = 2_000, 8_000, 50
    expected = pts.select { |_id, x, y| x >= xmin && x <= xmax && y <= ylimit }
                  .map { |id, x, y| [id, x, y] }.sort
    hits = tree.search(xmin, xmax, ylimit)
    expect(hits.sort).to eql(expected)
    expect(hits.size).to be > 0
    expect(hits.size).to be < 200 # hits really are sparse

    band = pts.count { |_id, x, _y| x >= xmin && x <= xmax }
    # the y limit prunes whole subtrees, so far fewer nodes are touched than
    # there are points in the x band, and far fewer than a full array scan
    expect(tree.last_visited).to be < band / 10
    expect(tree.last_visited).to be < n / 20

    # without a y limit the same band degenerates to a plain scan of the band
    tree.search(xmin, xmax, n)
    expect(tree.last_visited).to be > band / 2
  end

  it "matches a naive array scan under random inserts, deletes and queries" do
    rng = Random.new(7)
    points = {}
    300.times do |i|
      case rng.rand(3)
      when 0
        x, y = rng.rand(50), rng.rand(50)
        points[i] = [x, y]
        tree.insert(i, x, y)
      when 1
        next if points.empty?

        id = points.keys[rng.rand(points.size)]
        expect(tree.delete(id)).to eql([id, *points[id]])
        points.delete(id)
      else
        xmin = rng.rand(60) - 5
        xmax = xmin + rng.rand(30)
        ylimit = rng.rand(60) - 5
        expect(tree.search(xmin, xmax, ylimit).sort).to eql(naive_scan(points, xmin, xmax, ylimit))
        expect(tree.last_visited).to be <= points.size
      end
    end
    expect_valid(tree)
  end

  # In a priority search tree the minimum-y point of every subtree sits at
  # that subtree's root, so removing it must rotate the next-lowest-y point
  # up without breaking the heap order or the search order.
  describe "deleting the point that carries a subtree's minimum y" do
    it "deletes the global minimum-y point at the root" do
      [[1, 4, 10], [2, 2, 20], [3, 6, 30], [4, 1, 40], [5, 3, 50],
       [6, 5, 60], [7, 7, 5]].each { |id, x, y| tree.insert(id, x, y) }

      root = tree.instance_variable_get(:@root)
      expect(root.id).to eql(7) # smallest y sits at the root

      expect(tree.delete(7)).to eql([7, 7, 5])
      expect_valid(tree)
      new_root = tree.instance_variable_get(:@root)
      expect(new_root.id).to eql(1) # next-smallest y takes over the root
      expect(tree.search(0, 10, 100).sort).to eql(
        [[1, 4, 10], [2, 2, 20], [3, 6, 30], [4, 1, 40], [5, 3, 50], [6, 5, 60]]
      )
    end

    it "deletes every node one at a time without breaking the invariants" do
      rng = Random.new(99)
      pts = (0...40).map { |i| [i, rng.rand(30), rng.rand(30)] }
      pts.each do |gone_id, _x, _y|
        t = Containers::PrioritySearchTree.new
        pts.each { |id, x, y| t.insert(id, x, y) }
        t.delete(gone_id)
        expect_valid(t)
        remaining = pts.reject { |id, _x2, _y2| id == gone_id }
                       .map { |id, x, y| [id, x, y] }.sort
        expect(t.search(-1, 31, 31).sort).to eql(remaining)
      end
    end

    it "survives repeatedly deleting the current minimum-y point" do
      rng = Random.new(2024)
      points = {}
      200.times { |i| points[i] = [rng.rand(500), rng.rand(500)] }
      points.each { |id, (x, y)| tree.insert(id, x, y) }

      until points.empty?
        min_id = points.min_by { |id, (_x, y)| [y, id] }.first
        root = tree.instance_variable_get(:@root)
        expect(root.id).to eql(min_id) # the min-y point is the root
        expect(tree.delete(min_id)).to eql([min_id, *points[min_id]])
        points.delete(min_id)
        expect_valid(tree)
      end
      expect(tree).to be_empty
    end
  end
end
