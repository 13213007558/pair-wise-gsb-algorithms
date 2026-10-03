$: << File.join(File.expand_path(File.dirname(__FILE__)), '../lib')
require 'algorithms'

random = Random.new(20261004)
sequence = Array.new(256) { random.rand(-20..20) }
wavelet = Containers::WaveletMatrix.new(sequence)

queries = 5_000
mismatches = 0

queries.times do
  left = random.rand(sequence.length)
  right = random.rand((left + 1)..sequence.length)
  next if right - left > 12

  naive = sequence[left...right]
  sorted = naive.sort
  value = sequence[random.rand(left...right)]

  mismatches += 1 unless wavelet.frequency(value, left, right) == naive.count(value)

  sorted.each_with_index do |expected, k|
    mismatches += 1 unless wavelet.kth_smallest(left, right, k) == expected
  end
end

usage = wavelet.space_usage
puts "short interval comparisons: #{queries}"
puts "mismatches: #{mismatches}"
puts "levels: #{usage[:levels]}"
puts "bitmap bits: #{usage[:bitmap_bits]}"
puts "auxiliary bits: #{usage[:auxiliary_bits]}"
puts "total bits: #{usage[:total_bits]}"
puts "estimated packed bytes: #{usage[:estimated_bytes]}"

raise "Wavelet Matrix comparison failed" unless mismatches.zero?

