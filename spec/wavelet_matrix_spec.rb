$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::WaveletMatrix do
  def assert_matches_naive(sequence)
    wavelet = described_class.new(sequence)
    values = (sequence.min - 1..sequence.max + 1).to_a if sequence.any?

    expect(wavelet.size).to eq(sequence.length)
    expect(wavelet.empty?).to eq(sequence.empty?)

    (0..sequence.length).each do |prefix|
      values.to_a.each do |value|
        expect(wavelet.rank(value, prefix)).to eq(sequence[0, prefix].count(value))
      end
    end

    sequence.uniq.each do |value|
      positions = sequence.each_index.select { |index| sequence[index] == value }
      positions.each_with_index do |position, occurrence|
        expect(wavelet.select(value, occurrence)).to eq(position)
      end
      expect(wavelet.select(value, positions.length)).to be_nil
    end

    (0..sequence.length).each do |left|
      (left..sequence.length).each do |right|
        naive = sequence[left...right]

        values.to_a.each do |value|
          expect(wavelet.frequency(value, left, right)).to eq(naive.count(value))
          expect(wavelet.range_frequency(left, right, value)).to eq(naive.count(value))
        end

        values.to_a.each do |low_value|
          values.to_a.each do |high_value|
            expected = naive.count { |value| value >= low_value && value < high_value }
            expect(wavelet.range_count(low_value, high_value, left, right)).to eq(expected)
          end
        end

        if naive.empty?
          expect(wavelet.kth_smallest(left, right, 0)).to be_nil
          expect(wavelet.kth_largest(left, right, 0)).to be_nil
        else
          sorted = naive.sort
          sorted.each_with_index do |value, k|
            expect(wavelet.kth_smallest(left, right, k)).to eq(value)
            expect(wavelet.kth_largest(left, right, sorted.length - 1 - k)).to eq(value)
          end
          expect { wavelet.kth_smallest(left, right, sorted.length) }.to raise_error(RangeError)
        end
      end
    end

    wavelet
  end

  it "supports an empty sequence" do
    wavelet = described_class.new([])

    expect(wavelet.size).to eq(0)
    expect(wavelet).to be_empty
    expect(wavelet.rank(0, 0)).to eq(0)
    expect(wavelet.select(0, 0)).to be_nil
    expect(wavelet.frequency(0, 0, 0)).to eq(0)
    expect(wavelet.range_count(0, 1, 0, 0)).to eq(0)
    expect(wavelet.kth_smallest(0, 0, 0)).to be_nil
    expect(wavelet.kth_largest(0, 0, 0)).to be_nil
    expect(wavelet.space_usage).to include(
      levels: 0,
      bitmap_bits: 0,
      auxiliary_bits: 0,
      total_bits: 0
    )
  end

  it "handles repeated equal values without bitmap levels" do
    wavelet = assert_matches_naive([-7, -7, -7, -7])

    expect(wavelet.space_usage[:levels]).to eq(0)
    expect(wavelet.select(-7, 3)).to eq(3)
  end

  it "matches naive results on every short interval for fixed edge cases" do
    sequences = [
      [0],
      [-1],
      [5, 5, 5],
      [-3, -3, 2, 2, 0],
      [1, -1, 0, -2, 2, 1, -1, 0],
      [-8, 8, -8, 0, 8, 0, -1, 1]
    ]

    sequences.each { |sequence| assert_matches_naive(sequence) }
  end

  it "matches naive results on many random short intervals" do
    random = Random.new(20261004)
    reported = nil

    100.times do
      length = random.rand(0..18)
      sequence = Array.new(length) { random.rand(-4..4) }
      wavelet = assert_matches_naive(sequence)
      reported = wavelet.space_usage if sequence.length == 18
    end

    expect(reported[:bitmap_bits]).to be >= 0
    expect(reported[:auxiliary_bits]).to be_positive
    expect(reported[:total_bits]).to eq(reported[:bitmap_bits] + reported[:auxiliary_bits])
  end

  it "does not retain mutations made to the input array" do
    sequence = [-2, 3, -2, 0]
    wavelet = described_class.new(sequence)
    sequence[0] = 100
    sequence << 999

    expect(wavelet.frequency(-2, 0, wavelet.size)).to eq(2)
    expect(wavelet.size).to eq(4)
    expect(wavelet.kth_smallest(0, 4, 3)).to eq(3)
  end

  it "accepts a frozen input array" do
    sequence = [-2, 1, -2, 0].freeze
    expect { described_class.new(sequence) }.not_to raise_error
  end

  it "reports bitmap and auxiliary index space" do
    wavelet = described_class.new([-4, -3, 0, 1, 4, -4, 2, 1])
    usage = wavelet.space_usage

    expect(usage.keys).to contain_exactly(
      :levels, :bitmap_bits, :auxiliary_bits, :total_bits, :estimated_bytes
    )
    expect(usage[:bitmap_bits]).to eq(8 * usage[:levels])
    expect(usage[:auxiliary_bits]).to be_positive
    expect(usage[:estimated_bytes]).to be_positive
  end

  it "rejects non-integer sequences and invalid intervals" do
    expect { described_class.new([1, "2"]) }.to raise_error(ArgumentError)
    wavelet = described_class.new([1, 2])

    expect(wavelet.rank(1, -1)).to eq(0)
    expect { wavelet.frequency(1, -1, 2) }.to raise_error(RangeError)
    expect { wavelet.frequency(1, 2, 1) }.to raise_error(RangeError)
    expect { wavelet.frequency(1, 0, 3) }.to raise_error(RangeError)
    expect { wavelet.kth_smallest(0, 2, -1) }.to raise_error(RangeError)
  end
end
