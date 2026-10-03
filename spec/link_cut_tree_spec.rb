$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::LinkCutTree do
  def reference_path(adjacency, first, last)
    return [first] if first == last

    parents = { first => nil }
    queue = [first]

    until queue.empty?
      node = queue.shift
      break if node == last

      adjacency[node].each do |neighbor|
        next if parents.key?(neighbor)
        parents[neighbor] = node
        queue << neighbor
      end
    end

    return nil unless parents.key?(last)

    path = []
    node = last
    while node
      path << node
      node = parents[node]
    end
    path
  end

  it 'adds stable node objects and reports path aggregates' do
    tree = described_class.new
    first = tree.add_node(1)
    second = tree.add_node(2)
    third = tree.add_node(3)

    expect(tree.size).to eq(3)
    expect(tree.link(first, second)).to be(true)
    expect(tree.link(first, third)).to be(true)
    expect(tree.path_sum(second, third)).to eq(6)
    expect(tree.add_path(second, third, 10)).to eq(36)
    expect(tree.path_sum(second, third)).to eq(36)
    expect(first.value).to eq(11)
    expect(second.value).to eq(12)
    expect(third.value).to eq(13)

    tree.make_root(third)
    expect(tree.path_sum(first, second)).to eq(23)
    expect(first).to be(first)
    expect(second).to be(second)
    expect(third).to be(third)
  end

  it 'rejects links that would create cycles and cuts that do not exist' do
    tree = described_class.new
    first = tree.add_node
    second = tree.add_node
    third = tree.add_node

    expect(tree.link(first, second)).to be(true)
    expect(tree.link(first, first)).to be(false)
    expect(tree.link(second, first)).to be(false)
    expect(tree.link(first, second)).to be(false)
    expect(tree.connected?(first, third)).to be(false)
    expect(tree.cut(first, third)).to be(false)
    expect(tree.cut(first, second)).to be(true)
    expect(tree.cut(first, second)).to be(false)
    expect(tree.path_sum(first, second)).to be_nil
    expect(tree.add_path(first, second, 1)).to be_nil
    expect(second.value).to eq(0)
  end

  it 'updates single-node paths' do
    tree = described_class.new
    node = tree.add_node(4)

    expect(tree.path_sum(node, node)).to eq(4)
    expect(tree.add_path(node, node, 3)).to eq(7)
    expect(node.value).to eq(7)
    node.value = 2
    expect(tree.path_sum(node, node)).to eq(2)
  end

  it 'matches a traversal reference through random forest operations' do
    random = Random.new(20261004)
    node_count = 14
    operation_count = 500
    tree = described_class.new
    nodes = Array.new(node_count) { |index| tree.add_node(index) }
    values = Array.new(node_count) { |index| index }
    adjacency = Array.new(node_count) { [] }
    identities = nodes.dup

    compare_all_paths = lambda do
      node_count.times do |first|
        expect(nodes[first].value).to eq(values[first])
        node_count.times do |last|
          path = reference_path(adjacency, first, last)
          expected_sum = path && path.sum { |node| values[node] }

          expect(tree.connected?(nodes[first], nodes[last])).to eq(!path.nil?)
          expect(tree.path_sum(nodes[first], nodes[last])).to eq(expected_sum)
        end
      end
    end

    operation_count.times do |step|
      first = random.rand(node_count)
      last = random.rand(node_count)
      next if first == last

      path = reference_path(adjacency, first, last)
      case random.rand(10)
      when 0..2
        expected = path.nil?
        expect(tree.link(nodes[first], nodes[last])).to eq(expected)
        if expected
          adjacency[first] << last
          adjacency[last] << first
        end
      when 3..5
        expected = adjacency[first].include?(last)
        expect(tree.cut(nodes[first], nodes[last])).to eq(expected)
        if expected
          adjacency[first].delete(last)
          adjacency[last].delete(first)
        end
      when 6..7
        delta = random.rand(-9..20)
        expected_sum = path && path.sum { |node| values[node] + delta }
        expect(tree.add_path(nodes[first], nodes[last], delta)).to eq(expected_sum)
        path&.each { |node| values[node] += delta }
      else
        expect(tree.make_root(nodes[first])).to be(nodes[first])
      end

      expect(nodes).to match_array(identities)
      compare_all_paths.call
    end

    compare_all_paths.call
  end

  it 'does not repeatedly scan a long exposed path' do
    tree_class = Class.new(described_class) do
      attr_reader :rotations

      def initialize
        super
        @rotations = 0
      end

      private

      def rotate(node)
        @rotations += 1
        super
      end
    end

    length = 1024
    tree = tree_class.new
    nodes = Array.new(length) { tree.add_node(1) }
    (length - 1).times { |index| tree.link(nodes[index], nodes[index + 1]) }

    tree.add_path(nodes.first, nodes.last, 0)
    before = tree.rotations

    100.times do |index|
      tree.path_sum(nodes.first, nodes.last)
      tree.add_path(nodes.first, nodes.last, index % 5)
    end

    operations = 200
    average_rotations = (tree.rotations - before).to_f / operations
    expect(average_rotations).to be < Math.log2(length)
    expect(tree.path_sum(nodes.first, nodes.last)).to eq(length * (1 + (0...100).sum { |index| index % 5 }))
  end

  it 'rejects nodes from another tree and non-numeric values' do
    tree = described_class.new
    other_tree = described_class.new
    node = tree.add_node
    foreign_node = other_tree.add_node

    expect { tree.link(node, foreign_node) }.to raise_error(ArgumentError)
    expect { tree.add_node('bad') }.to raise_error(ArgumentError)
    expect { tree.add_path(node, node, 'bad') }.to raise_error(ArgumentError)
  end
end
