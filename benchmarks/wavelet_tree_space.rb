# Measures how the wavelet tree index size grows with the input size.
# Run with: ruby benchmarks/wavelet_tree_space.rb
$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'
require 'objspace'

def measured_bytes(array)
  GC.start
  before = ObjectSpace.memsize_of_all
  tree = Containers::WaveletTree.new(array)
  GC.start
  after = ObjectSpace.memsize_of_all
  [tree, after - before]
end

puts format('%8s %8s %12s %14s %12s %10s', 'n', 'range m', 'entries', 'entries/n', 'bytes', 'bytes/n')
[1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000, 200_000].each do |n|
  rng = Random.new(7)
  arr = Array.new(n) { rng.rand(-n..n) }
  tree, bytes = measured_bytes(arr)
  entries = tree.index_size
  puts format('%8d %8d %12d %14.2f %12d %10.1f', n, 2 * n + 1, entries,
              entries.to_f / n, bytes, bytes.to_f / n)
end

# Same n, wider value range: entries/n should track log2(m).
puts
puts 'fixed n = 50_000, varying value range m'
puts format('%12s %12s %14s %12s', 'range m', 'entries', 'entries/n', 'log2(m)')
n = 50_000
[10, 100, 1_000, 10_000, 100_000, 1_000_000].each do |m|
  rng = Random.new(7)
  arr = Array.new(n) { rng.rand(-m..m) }
  tree = Containers::WaveletTree.new(arr)
  puts format('%12d %12d %14.2f %12.1f', 2 * m + 1, tree.index_size,
              tree.index_size.to_f / n, Math.log2(2 * m + 1))
end
