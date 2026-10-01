$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'algorithms'

sizes = [128, 256, 512, 1_024, 2_048, 4_096]
random = Random.new(20261002)

puts 'n     nodes   nodes/n  index_bytes  bytes/n'
sizes.each do |size|
  values = Array.new(size) { random.rand(-1_000..1_000) }
  index = Containers::StaticRangeIndex.new(values)
  bytes = index.index_bytes

  puts format('%5d %7d %8.2f %11d %8.1f', size, index.index_nodes, index.index_nodes.to_f / size, bytes, bytes.to_f / size)
end
