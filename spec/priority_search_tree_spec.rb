$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::PrioritySearchTree do
  def expect_valid(node)
    return if node.nil?

    expect(node.height).to eql(1 + [node.left&.height || 0, node.right&.height || 0].max)
    expect(node.min_y).to eql([node.y, node.left&.min_y, node.right&.min_y].compact.min)

    if node.left
      expect(node.left.x <= node.x).to be(true)
      expect(node.left.sequence < node.sequence).to be(true) if node.left.x == node.x
    end
    if node.right
      expect(node.right.x >= node.x).to be(true)
      expect(node.right.sequence > node.sequence).to be(true) if node.right.x == node.x
    end

    factor = (node.left&.height || 0) - (node.right&.height || 0)
    expect(factor).to be_between(-1, 1)

    expect_valid(node.left)
    expect_valid(node.right)
  end

  it "supports duplicate coordinates with different IDs" do
    tree = described_class.new
    tree.insert(:a, 5, 2)
    tree.insert(:b, 5, 2)
    tree.insert(:c, 5, 3)

    expect(tree.size).to eql(3)
    expect(tree.query(5, 5, 2).map { |id, x, y| [id, x, y] }).to eql([[:a, 5, 2], [:b, 5, 2]])
  end

  it "does not require IDs at the same x to be comparable" do
    tree = described_class.new
    tree.insert(:symbol, 7, 1)
    tree.insert(42, 7, 1)

    expect(tree.query(7, 7, 1).map(&:first)).to eql([:symbol, 42])
    expect(tree.delete(42)).to eql([7, 1])
    expect(tree.query(7, 7, 1).map(&:first)).to eql([:symbol])
  end

  it "filters both x bounds and y" do
    tree = described_class.new({
      left: [1, 1],
      low: [5, 1],
      high: [5, 10],
      right: [9, 1]
    })

    expect(tree.query(2, 8, 5).to_a).to eql([[:low, 5, 1]])
  end

  it "deletes by ID and returns the deleted point" do
    tree = described_class.new(a: [1, 1], b: [2, 2])

    expect(tree.delete(:a)).to eql([1, 1])
    expect(tree.delete(:a)).to be_nil
    expect(tree.size).to eql(1)
    expect(tree.query(1, 2, 5).to_a).to eql([[:b, 2, 2]])
  end

  it "returns hits one at a time from a lazy enumerator" do
    tree = described_class.new
    (1..100).each { |x| tree.insert(x, x, x.even? ? 1 : 100) }
    enumerator = tree.query(1, 100, 1)

    first = enumerator.next
    second = enumerator.next
    expect(first).to eql([2, 2, 1])
    expect(second).to eql([4, 4, 1])
    expect(enumerator.access_count).to be <= 10
    expect(enumerator.to_a.size).to eql(50)
    expect(enumerator.access_count).to eql(tree.last_query_access_count)
    first_full_count = enumerator.access_count
    enumerator.rewind
    expect(enumerator.to_a.size).to eql(50)
    expect(enumerator.access_count).to eql(first_full_count)
  end

  it "prunes the whole tree when the root subtree minimum y exceeds the limit" do
    tree = described_class.new
    1000.times { |i| tree.insert(i, i, 100) }

    expect(tree.query(0, 999, 1).to_a).to be_empty
    expect(tree.last_query_access_count).to eql(1)
  end

  it "updates ancestor minimum y when deleting the point carrying a subtree minimum" do
    tree = described_class.new
    (1..31).each { |x| tree.insert(x + 100, x, 100) }
    tree.insert(1, 5, 1)
    tree.insert(2, 6, 2)

    before = tree.query(1, 31, 1).to_a
    expect(before).to eql([[1, 5, 1]])
    expect(tree.last_query_access_count).to be < tree.size

    expect(tree.delete(1)).to eql([5, 1])
    root = tree.instance_variable_get(:@root)
    expect_valid(root)

    expect(tree.query(1, 31, 1).to_a).to be_empty
    expect(tree.last_query_access_count).to eql(1)

    expect(tree.delete(2)).to eql([6, 2])
    expect_valid(tree.instance_variable_get(:@root))
    expect(tree.query(1, 31, 2).to_a).to be_empty
    expect(tree.last_query_access_count).to eql(1)
  end

  it "matches an array scan during random insertions and deletions" do
    random = Random.new(20261004)
    tree = described_class.new
    points = {}
    id = 0

    500.times do
      if points.empty? || random.rand < 0.7
        id += 1
        x = random.rand(0...100)
        y = random.rand(0...1000)
        tree.insert(id, x, y)
        points[id] = [x, y]
      else
        target = points.keys.sample(random: random)
        expect(tree.delete(target)).to eql(points.delete(target))
      end

      if random.rand < 0.25
        xmin = random.rand(0...80)
        xmax = xmin + random.rand(0...20)
        limit = random.rand(0...1000)

        expected = points.select do |point_id, (x, y)|
          x >= xmin && x <= xmax && y <= limit
        end.sort_by { |point_id, (x, y)| [x, point_id] }.map { |point_id, (x, y)| [point_id, x, y] }

        got = []
        accesses = tree.query(xmin, xmax, limit) { |point| got << point }

        expect(got).to eql(expected)
        expect(accesses).to be <= points.size
        expect_valid(tree.instance_variable_get(:@root))

        if limit < 10
          expect(accesses).to be < points.size unless expected.size == points.size
        end
      end
    end
  end

  it "rejects duplicate IDs and invalid range bounds" do
    tree = described_class.new(a: [1, 1])

    expect { tree.insert(:a, 2, 2) }.to raise_error(ArgumentError)
    expect { tree.query(9, 1, 0) }.to raise_error(ArgumentError)
    expect { described_class.new([]) }.to raise_error(ArgumentError)
  end
end
