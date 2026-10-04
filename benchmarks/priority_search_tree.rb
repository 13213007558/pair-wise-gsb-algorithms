$: << File.join(File.expand_path(File.dirname(__FILE__)), '../lib')
require 'algorithms'

N = 2000
UPDATES = 5000
QUERIES = 200
RANDOM = Random.new(20261004)

def scan(points, order, xmin, xmax, limit)
  accesses = 0
  hits = []

  points.each do |id, (x, y)|
    accesses += 1
    if x >= xmin && x <= xmax && y <= limit
      hits << [[x, order.fetch(id)], [id, x, y]]
    end
  end

  [hits.sort_by(&:first).map(&:last), accesses]
end

def build_dataset(count, random)
  tree = Containers::PrioritySearchTree.new
  points = {}

  count.times do |id|
    x = random.rand(0...1000)
    y = random.rand(100...1000)
    tree.insert(id, x, y)
    points[id] = [x, y]
  end

  [tree, points]
end

tree, points = build_dataset(N, RANDOM)
next_id = N
order = {}
N.times { |id| order[id] = id }

UPDATES.times do
  if points.size < N / 2 || RANDOM.rand < 0.6
    x = RANDOM.rand(0...1000)
    y = RANDOM.rand(100...1000)
    tree.insert(next_id, x, y)
    points[next_id] = [x, y]
    order[next_id] = order.size
    next_id += 1
  else
    id = points.keys.sample(random: RANDOM)
    tree.delete(id)
    points.delete(id)
  end
end

tree_accesses = 0
array_accesses = 0
tree_hits = 0

QUERIES.times do
  xmin = RANDOM.rand(0...950)
  xmax = xmin + RANDOM.rand(1...50)
  limit = RANDOM.rand(0...15)

  tree_result = []
  tree_accesses += tree.query(xmin, xmax, limit) { |point| tree_result << point }
  array_result, scanned = scan(points, order, xmin, xmax, limit)
  array_accesses += scanned

  raise 'query result mismatch' unless tree_result == array_result

  tree_hits += tree_result.size
end

puts 'Random updates, then sparse queries'
puts "  points: #{points.size}"
puts "  queries: #{QUERIES}"
puts "  hits: #{tree_hits}"
puts "  array scan node checks: #{array_accesses}"
puts "  priority search tree checks: #{tree_accesses}"
puts "  checks avoided: #{array_accesses - tree_accesses}"
puts

def deletion_pruning_run(random)
  tree = Containers::PrioritySearchTree.new
  points = {}
  order = {}

  500.times do |id|
    x = random.rand(0...1000)
    y = random.rand(100...1000)
    tree.insert(id, x, y)
    points[id] = [x, y]
    order[id] = id
  end

  tree.insert(:subtree_minimum, 250, 1)
  points[:subtree_minimum] = [250, 1]
  order[:subtree_minimum] = order.size

  before = []
  before_accesses = tree.query(0, 999, 1) { |point| before << point }
  expected, _accesses = scan(points, order, 0, 999, 1)
  raise 'subtree minimum query mismatch' unless before == expected

  deleted = tree.delete(:subtree_minimum)
  points.delete(:subtree_minimum)

  after = []
  after_accesses = tree.query(0, 999, 1) { |point| after << point }
  expected, _accesses = scan(points, order, 0, 999, 1)
  raise 'post-deletion query mismatch' unless after == expected

  {
    deleted: deleted,
    size: points.size,
    before_hits: before.size,
    before_accesses: before_accesses,
    after_hits: after.size,
    after_accesses: after_accesses,
    array_accesses: points.size
  }
end

stats = deletion_pruning_run(RANDOM)
puts 'Delete the point carrying a subtree minimum y'
puts "  deleted: #{stats[:deleted].inspect}"
puts "  before: #{stats[:before_hits]} hit, #{stats[:before_accesses]} tree checks / #{stats[:size] + 1} array checks"
puts "  after:  #{stats[:after_hits]} hits, #{stats[:after_accesses]} tree checks / #{stats[:array_accesses]} array checks"
