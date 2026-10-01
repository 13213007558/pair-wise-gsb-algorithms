$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::RTree do
  def intersects?(first, second)
    !(first[2] < second[0] || second[2] < first[0] ||
      first[3] < second[1] || second[3] < first[1])
  end

  def contains?(outer, inner)
    outer[0] <= inner[0] && outer[1] <= inner[1] &&
      outer[2] >= inner[2] && outer[3] >= inner[3]
  end

  def walk(node, &block)
    yield node
    node.entries.each { |entry| walk(entry, &block) } unless node.leaf
  end

  def check_node(node, tree, root = false)
    expect(node.entries.size).to be <= tree.capacity
    expect(node.entries.size).to be >= (tree.capacity / 2.0).ceil unless root || node.leaf && node.entries.empty?

    if node.entries.any?
      expected = node.entries.map { |entry| entry.is_a?(described_class::Node) ? entry.bounding : entry.rectangle }.reduce do |combined, rectangle|
        [
          [combined[0], rectangle[0]].min,
          [combined[1], rectangle[1]].min,
          [combined[2], rectangle[2]].max,
          [combined[3], rectangle[3]].max
        ]
      end
      expect(node.bounding).to eq(expected)
    else
      expect(node.bounding).to be_nil
    end

    node.entries.each { |child| check_node(child, tree) } unless node.leaf
  end

  it "keeps different IDs at the same rectangle and uses boundary-touching intersection" do
    tree = described_class.new(3)
    tree.insert(:a, [0, 0, 2, 2])
    tree.insert(:b, [0, 0, 2, 2])

    expect(tree.intersecting([2, 2, 3, 3])).to match_array(%i[a b])
    expect(tree.contained([0, 0, 2, 2])).to match_array(%i[a b])
    expect(tree.contained([2, 2, 3, 3])).to be_empty
  end

  it "updates an ID without leaving an entry at the old rectangle" do
    tree = described_class.new(3)
    1.upto(20) { |id| tree.insert(id, [id, id, id + 1, id + 1]) }
    tree.update(10, [100, 100, 101, 101])

    expect(tree.size).to eq(20)
    expect(tree.rectangle(10)).to eq([100, 100, 101, 101])
    expect(tree.intersecting([0, 0, 30, 30])).not_to include(10)
    expect(tree.intersecting([99, 99, 102, 102])).to eq([10])

    walk(tree.root) do |node|
      next if node.leaf

      node.entries.each { |child| expect(node.bounding).to satisfy { |box| contains?(box, child.bounding) } }
    end
  end

  it "continually updates the same ID across distant rectangles" do
    tree = described_class.new(4)

    1.upto(50) do |n|
      x = n.even? ? -1_000 - n : 1_000 + n
      tree.update(:moving, [x, x, x + 1, x + 1])

      expect(tree.size).to eq(1)
      expect(tree.intersecting([-2_000, -2_000, 2_000, 2_000])).to eq([:moving])
      expect(tree.intersecting([x, x, x + 1, x + 1])).to eq([:moving])
      expect(tree.valid?).to be(true)
    end
  end

  it "remains usable after deleting most entries" do
    tree = described_class.new(4)
    entries = {}
    1.upto(80) do |id|
      rectangle = [id % 10, (id / 10) % 8, id % 10 + 1, ((id / 10) % 8) + 1]
      entries[id] = rectangle
      tree.insert(id, rectangle)
    end

    1.upto(55) { |id| expect(tree.delete(id)).to eq(entries.delete(id)) }

    expect(tree.size).to eq(25)
    expect(tree.valid?).to be(true)
    check_node(tree.root, tree, true)

    query = [2, 1, 8, 7]
    expected = entries.select { |_id, rectangle| intersects?(rectangle, query) }.keys
    expect(tree.intersecting(query)).to match_array(expected)

    contained_expected = entries.select { |_id, rectangle| contains?(query, rectangle) }.keys
    expect(tree.contained(query)).to match_array(contained_expected)
  end

  it "matches a linear scan through randomized insertions, updates, and deletions" do
    tree = described_class.new(5)
    entries = {}
    random = Random.new(20261002)

    1.upto(80) do |id|
      rectangle = [random.rand(-20..20), random.rand(-20..20), 0, 0]
      rectangle[2] = rectangle[0] + random.rand(0..5)
      rectangle[3] = rectangle[1] + random.rand(0..5)
      entries[id] = rectangle
      tree.insert(id, rectangle)
    end

    300.times do
      id = random.rand(1..100)

      case random.rand(3)
      when 0
        if entries.key?(id)
          expect(tree.delete(id)).to eq(entries.delete(id))
        else
          expect(tree.delete(id)).to be_nil
        end
      else
        rectangle = [random.rand(-30..30), random.rand(-30..30), 0, 0]
        rectangle[2] = rectangle[0] + random.rand(0..6)
        rectangle[3] = rectangle[1] + random.rand(0..6)
        entries[id] = rectangle
        tree.insert(id, rectangle)
      end

      expect(tree.size).to eq(entries.size)
      expect(tree.valid?).to be(true)

      query = [random.rand(-32..28), random.rand(-32..28), random.rand(0..10), random.rand(0..10)]
      query[2] += query[0]
      query[3] += query[1]

      intersect_expected = entries.select { |_id, rectangle| intersects?(rectangle, query) }.keys
      contained_expected = entries.select { |_id, rectangle| contains?(query, rectangle) }.keys
      containing_expected = entries.select { |_id, rectangle| contains?(rectangle, query) }.keys

      expect(tree.intersecting(query)).to match_array(intersect_expected)
      expect(tree.contained(query)).to match_array(contained_expected)
      expect(tree.containing(query)).to match_array(containing_expected)
    end
  end

  it "rejects invalid rectangles" do
    tree = described_class.new

    expect { tree.insert(1, [0, 0, 1]) }.to raise_error(ArgumentError)
    expect { tree.insert(1, [2, 0, 1, 2]) }.to raise_error(ArgumentError)
    expect { described_class.new(1) }.to raise_error(ArgumentError)
  end

  it "maintains invariants with minimum node capacity" do
    tree = described_class.new(2)
    random = Random.new(2)
    entries = {}

    60.times do |n|
      id = n + 1
      rectangle = [random.rand(-10..10), random.rand(-10..10), 0, 0]
      rectangle[2] = rectangle[0] + random.rand(0..3)
      rectangle[3] = rectangle[1] + random.rand(0..3)
      entries[id] = rectangle
      tree.insert(id, rectangle)
    end

    40.times { |n| entries.delete(n + 1) && tree.delete(n + 1) }

    expect(tree.size).to eq(20)
    expect(tree.valid?).to be(true)
    check_node(tree.root, tree, true)
  end
end
