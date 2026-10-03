$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'
require 'benchmark'

# Straightforward reference implementation used to cross-check the
# Link-Cut Tree: it keeps an adjacency list and walks the tree directly.
class ReferenceForest
  def initialize(values)
    @values = values.dup
    @adj = Array.new(values.size) { [] }
  end

  def connected?(a, b)
    return true if a == b
    seen = Array.new(@adj.size, false)
    stack = [a]
    seen[a] = true
    until stack.empty?
      node = stack.pop
      return true if node == b
      @adj[node].each do |neighbor|
        next if seen[neighbor]
        seen[neighbor] = true
        stack << neighbor
      end
    end
    false
  end

  def edge?(a, b)
    @adj[a].include?(b)
  end

  def link(a, b)
    @adj[a] << b
    @adj[b] << a
  end

  def cut(a, b)
    @adj[a].delete(b)
    @adj[b].delete(a)
  end

  # Returns the node indices on the unique path between a and b.
  def path(a, b)
    parent = { a => nil }
    queue = [a]
    until queue.empty?
      node = queue.shift
      break if node == b
      @adj[node].each do |neighbor|
        next if parent.key?(neighbor)
        parent[neighbor] = node
        queue << neighbor
      end
    end
    result = []
    node = b
    until node.nil?
      result << node
      node = parent[node]
    end
    result
  end

  def path_sum(a, b)
    path(a, b).sum { |i| @values[i] }
  end

  def path_add(a, b, delta)
    path(a, b).each { |i| @values[i] += delta }
  end

  def set_value(i, value)
    @values[i] = value
  end

  def value(i)
    @values[i]
  end
end

describe Containers::LinkCutTree do
  before(:each) do
    @tree = Containers::LinkCutTree.new
  end

  def build_chain(size)
    nodes = Array.new(size) { |i| @tree.make_node(i + 1) }
    nodes.each_cons(2) { |a, b| @tree.link(a, b) }
    nodes
  end

  describe "basic structure" do
    it "creates isolated nodes that are only connected to themselves" do
      a = @tree.make_node(5)
      b = @tree.make_node(7)
      expect(@tree.connected?(a, a)).to be true
      expect(@tree.connected?(a, b)).to be false
      expect(a.value).to eql(5)
      expect(@tree.size).to eql(2)
    end

    it "links nodes and answers connectivity" do
      a, b, c = Array.new(3) { @tree.make_node(0) }
      @tree.link(a, b)
      expect(@tree.connected?(a, b)).to be true
      expect(@tree.connected?(a, c)).to be false
      @tree.link(b, c)
      expect(@tree.connected?(a, c)).to be true
    end

    it "rejects a link that would create a cycle" do
      a, b, c = Array.new(3) { @tree.make_node(0) }
      @tree.link(a, b)
      @tree.link(b, c)
      expect { @tree.link(a, c) }.to raise_error(ArgumentError)
      expect { @tree.link(a, b) }.to raise_error(ArgumentError)
      expect { @tree.link(a, a) }.to raise_error(ArgumentError)
    end

    it "cuts edges and rejects cutting non-existent edges" do
      a, b, c = Array.new(3) { @tree.make_node(0) }
      @tree.link(a, b)
      @tree.link(b, c)
      expect { @tree.cut(a, c) }.to raise_error(ArgumentError)
      @tree.cut(a, b)
      expect(@tree.connected?(a, b)).to be false
      expect(@tree.connected?(b, c)).to be true
      expect { @tree.cut(a, b) }.to raise_error(ArgumentError)
    end

    it "supports make_root without changing connectivity or sums" do
      nodes = build_chain(5)
      expect(@tree.path_sum(nodes.first, nodes.last)).to eql(15)
      @tree.make_root(nodes[2])
      expect(@tree.path_sum(nodes.first, nodes.last)).to eql(15)
      expect(@tree.connected?(nodes.first, nodes.last)).to be true
      @tree.make_root(nodes.last)
      expect(@tree.path_sum(nodes.first, nodes.last)).to eql(15)
    end
  end

  describe "path aggregation" do
    it "computes path sums" do
      nodes = build_chain(5) # values 1..5
      expect(@tree.path_sum(nodes[0], nodes[4])).to eql(15)
      expect(@tree.path_sum(nodes[1], nodes[3])).to eql(9)
      expect(@tree.path_sum(nodes[2], nodes[2])).to eql(3)
      expect(@tree.path_sum(nodes[4], nodes[0])).to eql(15)
    end

    it "adds to whole paths and reflects it in later sums" do
      nodes = build_chain(5)
      @tree.path_add(nodes[0], nodes[4], 10)
      expect(@tree.path_sum(nodes[0], nodes[4])).to eql(15 + 50)
      expect(@tree.path_sum(nodes[1], nodes[2])).to eql(2 + 10 + 3 + 10)
      @tree.path_add(nodes[1], nodes[3], 100)
      expect(@tree.path_sum(nodes[0], nodes[4])).to eql(65 + 300)
      expect(@tree.path_sum(nodes[0], nodes[0])).to eql(1 + 10)
    end

    it "keeps node values readable after path_add" do
      nodes = build_chain(3)
      @tree.path_add(nodes[0], nodes[2], 5)
      expect(nodes.map { |n| @tree.get_value(n) }).to eql([6, 7, 8])
    end

    it "supports set_value on single nodes" do
      nodes = build_chain(3)
      @tree.set_value(nodes[1], 100)
      expect(@tree.path_sum(nodes[0], nodes[2])).to eql(1 + 100 + 3)
      expect(nodes[1].value).to eql(100)
    end
  end

  describe "node identity" do
    it "keeps node object identity stable across cut, link and make_root" do
      nodes = build_chain(4)
      snapshot = nodes.map { |n| [n.object_id, n] }
      @tree.make_root(nodes[1])
      @tree.cut(nodes[1], nodes[2])
      expect(@tree.connected?(nodes[0], nodes[2])).to be false
      @tree.link(nodes[0], nodes[3])
      @tree.make_root(nodes[3])
      snapshot.each_with_index do |(id, node), i|
        expect(node.object_id).to eql(id)
        expect(node).to equal(nodes[i])
      end
      expect(@tree.connected?(nodes[0], nodes[3])).to be true
      expect(@tree.connected?(nodes[0], nodes[2])).to be true
    end
  end

  describe "randomized cross-check" do
    it "matches a direct reference implementation over hundreds of random operations" do
      rng = Random.new(20_261_002)
      node_count = 40
      values = Array.new(node_count) { rng.rand(-50..50) }
      nodes = values.map { |v| @tree.make_node(v) }
      reference = ReferenceForest.new(values)
      edges = []

      600.times do
        case rng.rand(8)
        when 0, 1 # link
          a, b = Array.new(2) { rng.rand(node_count) }
          if a != b && !reference.connected?(a, b)
            @tree.link(nodes[a], nodes[b])
            reference.link(a, b)
            edges << [a, b]
          else
            expect { @tree.link(nodes[a], nodes[b]) }.to raise_error(ArgumentError)
          end
        when 2 # cut
          if !edges.empty? && rng.rand(4) > 0
            a, b = edges.delete_at(rng.rand(edges.size))
            @tree.cut(nodes[a], nodes[b])
            reference.cut(a, b)
          else
            a, b = Array.new(2) { rng.rand(node_count) }
            next if reference.edge?(a, b)
            expect { @tree.cut(nodes[a], nodes[b]) }.to raise_error(ArgumentError)
          end
        when 3 # make_root
          @tree.make_root(nodes[rng.rand(node_count)])
        when 4 # connected?
          a, b = Array.new(2) { rng.rand(node_count) }
          expect(@tree.connected?(nodes[a], nodes[b])).to eql(reference.connected?(a, b))
        when 5, 6 # path query / update
          a, b = Array.new(2) { rng.rand(node_count) }
          next unless reference.connected?(a, b)
          if rng.rand(2).zero?
            expect(@tree.path_sum(nodes[a], nodes[b])).to eql(reference.path_sum(a, b))
          else
            delta = rng.rand(-20..20)
            @tree.path_add(nodes[a], nodes[b], delta)
            reference.path_add(a, b, delta)
          end
        when 7 # set_value
          i = rng.rand(node_count)
          value = rng.rand(-100..100)
          @tree.set_value(nodes[i], value)
          reference.set_value(i, value)
        end
      end

      # Final full comparison of connectivity and all pairwise sums in components.
      node_count.times do |i|
        expect(@tree.get_value(nodes[i])).to eql(reference.value(i))
        node_count.times do |j|
          expect(@tree.connected?(nodes[i], nodes[j])).to eql(reference.connected?(i, j))
          next unless reference.connected?(i, j)
          expect(@tree.path_sum(nodes[i], nodes[j])).to eql(reference.path_sum(i, j))
        end
      end
    end
  end

  describe "long chain" do
    it "stays correct and does not degrade to scanning whole paths" do
      chain_size = 20_000
      queries = 1_000
      nodes = nil
      elapsed = Benchmark.realtime do
        nodes = build_chain(chain_size)
        # values are 1..chain_size; full path sum is n*(n+1)/2
        expect(@tree.path_sum(nodes.first, nodes.last)).to eql(chain_size * (chain_size + 1) / 2)

        rng = Random.new(42)
        adds = Array.new(chain_size + 1, 0) # difference array for verification
        queries.times do
          i = rng.rand(chain_size)
          j = rng.rand(chain_size)
          lo, hi = [i, j].minmax
          if rng.rand(2).zero?
            delta = rng.rand(1..10)
            @tree.path_add(nodes[lo], nodes[hi], delta)
            adds[lo] += delta
            adds[hi + 1] -= delta
          else
            @tree.path_sum(nodes[lo], nodes[hi])
          end
        end

        # Verify final values against the difference array.
        spot_checks = 200
        spot_checks.times do
          i = rng.rand(chain_size)
          expected = i + 1 + adds[0..i].sum
          expect(@tree.path_sum(nodes[i], nodes[i])).to eql(expected)
        end
        running = 0
        total = (0...chain_size).sum { |i| running += adds[i]; i + 1 + running }
        expect(@tree.path_sum(nodes.first, nodes.last)).to eql(total)
      end
      # An implementation scanning whole paths would need O(chain_size)
      # work per operation (hundreds of millions of steps here); the
      # Link-Cut Tree finishes in well under this generous bound.
      expect(elapsed).to be < 30
    end
  end
end
