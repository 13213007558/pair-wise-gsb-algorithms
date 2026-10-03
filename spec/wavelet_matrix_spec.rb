$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::WaveletMatrix do
  def naive_kth_smallest(array, distinct_values, left, right, k)
    seen = 0

    distinct_values.each do |value|
      seen += left.upto(right - 1).count { |index| array[index] == value }
      return value if seen > k
    end
  end

  def assert_matches_naive(array, wavelet_matrix = Containers::WaveletMatrix.new(array))
    values = array.uniq.sort
    array.length.times do |left|
      (left..array.length).each do |right|
        values.each do |value|
          expected = left.upto(right - 1).count { |index| array[index] == value }
          expect(wavelet_matrix.rank(value, left, right)).to eq(expected)
          expect(wavelet_matrix.frequency(value, left, right)).to eq(expected)
        end

        (right - left).times do |k|
          expect(wavelet_matrix.kth_smallest(left, right, k)).to eq(
            naive_kth_smallest(array, values, left, right, k)
          )
        end
      end
    end

    values.each do |value|
      occurrences = []
      array.each_with_index do |item, index|
        occurrences << index if item == value
      end

      occurrences.each_with_index do |index, occurrence_index|
        expect(wavelet_matrix.select(value, occurrence_index + 1)).to eq(index)
        expect(wavelet_matrix.rank(value, index)).to eq(occurrence_index)
        expect(wavelet_matrix.rank(value, index + 1)).to eq(occurrence_index + 1)
      end
    end
  end

  it "supports an empty sequence and empty intervals" do
    wavelet_matrix = Containers::WaveletMatrix.new([])

    expect(wavelet_matrix).to be_empty
    expect(wavelet_matrix.length).to eq(0)
    expect(wavelet_matrix.rank(0, 0, 0)).to eq(0)
    expect(wavelet_matrix.frequency(0, 0, 0)).to eq(0)
    expect { wavelet_matrix.kth_smallest(0, 0, 0) }.to raise_error(RangeError)
    expect { wavelet_matrix.select(0, 1) }.to raise_error(RangeError)

    usage = wavelet_matrix.space_usage
    expect(usage[:levels]).to eq(0)
    expect(usage[:bitmap_bits]).to eq(0)
    expect(usage[:total_bytes]).to eq(0)
  end

  it "matches naive queries for every short interval with repeated negative values" do
    values = [-3, -1, 0, 2, -3, 2]
    arrays = []

    5.times do |length|
      arrays.concat(values.repeated_permutation(length).to_a) if length <= 3
    end

    arrays.each { |array| assert_matches_naive(array) }
  end

  it "matches naive queries for randomized short and medium intervals" do
    srand(12_345)

    80.times do
      array = Array.new(rand(1..20)) { rand(-7..7) }
      assert_matches_naive(array)
    end
  end

  it "handles bit and word boundaries" do
    [0, 1, 62, 63, 64, 65, 127, 128, 129].each do |length|
      array = Array.new(length) { |index| [0, 1, -1, index % 5 - 2].sample(random: Random.new(length + index)) }
      assert_matches_naive(array)
    end
  end

  it "supports uniform sequences where intermediate bit vectors are all zero or all one" do
    [[-8, -8, -8], [0, 0, 0], [8, 8, 8]].each do |array|
      wavelet_matrix = Containers::WaveletMatrix.new(array)

      array.each_with_index do |value, index|
        expect(wavelet_matrix.select(value, index + 1)).to eq(index)
      end
      expect(wavelet_matrix.kth_smallest(0, array.length, array.length - 1)).to eq(array.first)
    end
  end

  it "does not modify the input array" do
    array = [3, -1, 2, -1, 0]
    original = array.dup
    Containers::WaveletMatrix.new(array)
    expect(array).to eq(original)
  end

  it "rejects invalid inputs and bounds" do
    wavelet_matrix = Containers::WaveletMatrix.new([1, 2])

    expect { Containers::WaveletMatrix.new([1, 2.0]) }.to raise_error(ArgumentError)
    expect { wavelet_matrix.kth_smallest(0, 2, 2) }.to raise_error(RangeError)
    expect { wavelet_matrix.kth_smallest(-1, 1, 0) }.to raise_error(ArgumentError)
    expect { wavelet_matrix.kth_smallest(1, 0, 0) }.to raise_error(ArgumentError)
    expect { wavelet_matrix.kth_smallest(0, 3, 0) }.to raise_error(RangeError)
    expect { wavelet_matrix.select(1, 0) }.to raise_error(ArgumentError)
    expect { wavelet_matrix.select(3, 1) }.to raise_error(RangeError)
  end

  it "reports packed bitmap and auxiliary index space" do
    wavelet_matrix = Containers::WaveletMatrix.new((-40...88).to_a)
    usage = wavelet_matrix.space_usage

    expect(usage[:length]).to eq(128)
    expect(usage[:levels]).to eq(7)
    expect(usage[:bitmap_bits]).to eq(128 * 7)
    expect(usage[:bitmap_bytes]).to eq(2 * 7 * 8)
    expect(usage[:rank_index_bytes]).to eq(3 * 7 * 8)
    expect(usage[:boundary_index_bytes]).to eq(7 * 8)
    expect(usage[:auxiliary_index_bytes]).to eq(
      usage[:rank_index_bytes] + usage[:boundary_index_bytes]
    )
    expect(usage[:total_bytes]).to eq(usage[:bitmap_bytes] + usage[:auxiliary_index_bytes])
    expect(usage[:bit_vectors].length).to eq(7)

    usage[:bit_vectors].each do |bit_vector_usage|
      expect(bit_vector_usage[:bitmap_bytes]).to eq(16)
      expect(bit_vector_usage[:rank_index_bytes]).to eq(24)
      expect(bit_vector_usage[:total_bytes]).to eq(40)
    end
  end
end
