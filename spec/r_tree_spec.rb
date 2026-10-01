$LOAD_PATH << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::RTree do
  def intersects?(rectangle, other)
    rectangle[0] <= other[2] && other[0] <= rectangle[2] &&
      rectangle[1] <= other[3] && other[1] <= rectangle[3]
  end

  def contains?(outer, inner)
    outer[0] <= inner[0] && outer[1] <= inner[1] &&
      inner[2] <= outer[2] && inner[3] <= outer[3]
  end

  def random_rectangle(random)
    min_x = random.rand(12)
    min_y = random.rand(12)
    [min_x, min_y, min_x + random.rand(3), min_y + random.rand(3)]
  end

  def walk_nodes(node, is_root = true, &block)
    yield(node, is_root)
    if node.entries.first&.child
      node.entries.each do |entry|
        expect(entry.rectangle).to eq(Containers::RTree.bounding_box(
          entry.child.entries.map(&:rectangle)
        ))
        entry.rectangle.each_with_index do |coordinate, index|
          expected = entry.child.bounding_box[index]
          expect(coordinate).to eq(expected)
        end
        walk_nodes(entry.child, false, &block)
      end
    end
  end

  it "stores duplicate coordinates with distinct IDs" do
    tree = described_class.new
    rectangle = [3, 4, 5, 6]
    10.times { |id| tree.insert(id, rectangle) }

    expect(tree.size).to eq(10)
    expect(tree.find_intersecting(rectangle).sort).to eq((0...10).to_a)
    expect(tree.delete(4)).to eq(rectangle)
    expect(tree.find_intersecting(rectangle).sort).to eq([0, 1, 2, 3, 5, 6, 7, 8, 9])
  end

  it "treats edge and corner contact as intersection" do
    tree = described_class.new(
      1 => [0, 0, 1, 1],
      2 => [1, 1, 2, 2],
      3 => [2, 1, 3, 2],
      4 => [3, 3, 4, 4]
    )

    expect(tree.find_intersecting([1, 0, 2, 1])).to contain_exactly(1, 2, 3)
    expect(tree.find_intersecting([1, 1, 1, 1])).to contain_exactly(1, 2)
    expect(tree.find_contained([0, 0, 3, 3])).to contain_exactly(1, 2, 3)
    expect(tree.find_containing([1, 1, 1, 1])).to contain_exactly(1, 2)
  end

  it "supports points as zero-area rectangles" do
    tree = described_class.new(1 => [2, 3, 2, 3], 2 => [2, 3, 2, 3])

    expect(tree.find_intersecting([2, 3, 2, 3])).to contain_exactly(1, 2)
    expect(tree.find_intersecting([1, 1, 1, 1])).to be_empty
  end

  it "accepts initial pairs and common query aliases" do
    tree = described_class.new([[:a, [0, 0, 2, 2]], [:b, [1, 1, 3, 3]]], 4)

    expect(tree.intersecting([2, 2, 2, 2])).to contain_exactly(:a, :b)
    expect(tree.contained_in([0, 0, 3, 3])).to contain_exactly(:a, :b)
    expect(tree.containing([2, 2, 2, 2])).to contain_exactly(:a, :b)
    expect(tree.containing([3, 3, 3, 3])).to contain_exactly(:b)
    expect(tree.search([2, 2, 2, 2], :intersection)).to contain_exactly(:a, :b)
  end

  it "replaces an ID without leaving its old rectangle in the tree" do
    tree = described_class.new
    tree.insert(7, [0, 0, 1, 1])
    tree.update(7, [10, 10, 11, 11])

    expect(tree.size).to eq(1)
    expect(tree[7]).to eq([10, 10, 11, 11])
    expect(tree.find_intersecting([0, 0, 1, 1])).to be_empty
    expect(tree.find_intersecting([10, 10, 11, 11])).to eq([7])

    20.times do |index|
      rectangle = index.even? ? [-20, -20, -19, -19] : [20, 20, 21, 21]
      tree[7] = rectangle
      expect(tree.size).to eq(1)
      expect(tree.find_intersecting([10, 10, 11, 11])).to be_empty
      expect(tree.find_intersecting(rectangle)).to eq([7])
    end
  end

  it "remains usable and valid after deleting most entries" do
    random = Random.new(4242)
    reference = {}
    tree = described_class.new(3)

    120.times do |id|
      rectangle = random_rectangle(random)
      reference[id] = rectangle
      tree.insert(id, rectangle)
    end

    expect(tree).to be_valid

    deleted_ids = reference.keys.sample(80, random: random)
    deleted_ids.each { |id| expect(tree.delete(id)).to eq(reference.delete(id)) }

    expect(tree.size).to eq(40)
    expect(tree).to be_valid

    query = [2, 2, 10, 10]
    expected = reference.select { |_, rectangle| intersects?(rectangle, query) }.keys
    expect(tree.find_intersecting(query)).to contain_exactly(*expected)

    40.times do |id|
      rectangle = random_rectangle(random)
      reference["new-#{id}"] = rectangle
      tree.insert("new-#{id}", rectangle)
    end

    expect(tree.size).to eq(80)
    expect(tree).to be_valid
    query = [0, 0, 14, 14]
    expected = reference.select { |_, rectangle| intersects?(rectangle, query) }.keys
    expect(tree.find_intersecting(query)).to contain_exactly(*expected)
  end

  it "matches a linear scan across randomized inserts, updates, deletes, and queries" do
    [3, 4, 5].each do |capacity|
      random = Random.new(9876 + capacity)
      reference = {}
      tree = described_class.new(capacity)

      600.times do
        id = random.rand(60)
        case random.rand(4)
        when 0, 1
          rectangle = random_rectangle(random)
          expect(tree.insert(id, rectangle)).to eq(rectangle)
          reference[id] = rectangle
        when 2
          expect(tree.delete(id)).to eq(reference.delete(id))
        else
          query = random_rectangle(random)
          expected = reference.select { |_, rectangle| intersects?(rectangle, query) }.keys
          expect(tree.find_intersecting(query)).to contain_exactly(*expected)

          expected = reference.select { |_, rectangle| contains?(query, rectangle) }.keys
          expect(tree.find_contained(query)).to contain_exactly(*expected)

          expected = reference.select { |_, rectangle| contains?(rectangle, query) }.keys
          expect(tree.find_containing(query)).to contain_exactly(*expected)
        end

        expect(tree.size).to eq(reference.size)
        expect(tree.to_h).to eq(reference)
        expect(tree).to be_valid
      end

      walk_nodes(tree.root) do |node, is_root|
        expect(node.entries.size).to be <= capacity
        expect(node.entries.size).to be >= (capacity / 2) unless is_root
      end
    end
  end

  it "keeps one leaf entry per ID after repeated far-apart updates" do
    tree = described_class.new(5)
    50.times { |id| tree.insert(id, [0, 0, 1, 1]) }
    100.times { |index| tree.insert(25, index.even? ? [-100, -100, -99, -99] : [100, 100, 101, 101]) }

    occurrences = Hash.new(0)
    walk = lambda do |node|
      if node.leaf?
        node.entries.each { |entry| occurrences[entry.id] += 1 }
      else
        node.entries.each { |entry| walk.call(entry.child) }
      end
    end
    walk.call(tree.root)

    expect(occurrences[25]).to eq(1)
    expect(occurrences.values.sum).to eq(50)
    expect(tree.find_intersecting([0, 0, 1, 1])).not_to include(25)
  end

  it "validates rectangles and node capacity" do
    expect { described_class.new(2) }.to raise_error(ArgumentError)
    tree = described_class.new
    expect { tree.insert(1, [0, 0, 1]) }.to raise_error(ArgumentError)
    expect { tree.insert(1, [2, 2, 1, 3]) }.to raise_error(ArgumentError)
    expect(tree).to be_empty
  end
end
