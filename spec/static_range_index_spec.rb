$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::StaticRangeIndex do
  let(:values) { [3, -1, 3, 2] }
  let(:index) { described_class.new(values) }

  it 'answers range kth queries with zero-based half-open ranges' do
    expect(index.kth(1, 4, 1)).to eq(-1)
    expect(index.kth(1, 4, 2)).to eq(2)
    expect(index.kth(1, 4, 3)).to eq(3)
    expect(index.kth(0, 4, 4)).to eq(3)
  end

  it 'counts occurrences of a value in a range' do
    expect(index.count(3, 1, 4)).to eq(1)
    expect(index.count(3, 0, 4)).to eq(2)
    expect(index.count(-1, 0, 4)).to eq(1)
    expect(index.count(7, 0, 4)).to eq(0)
  end

  it 'counts values below a threshold in a range' do
    expect(index.count_less(3, 1, 4)).to eq(2)
    expect(index.count_less(-2, 0, 4)).to eq(0)
    expect(index.count_less(4, 0, 4)).to eq(4)
  end

  it 'distinguishes empty ranges from out-of-range k values' do
    expect { index.kth(1, 1, 1) }.to raise_error(Containers::StaticRangeIndex::EmptyRangeError)
    expect { index.kth(0, 2, 3) }.to raise_error(Containers::StaticRangeIndex::KOutOfRangeError)
    expect { index.kth(0, 2, 0) }.to raise_error(Containers::StaticRangeIndex::KOutOfRangeError)
  end

  it 'rejects ranges outside the indexed array' do
    expect { index.kth(-1, 2, 1) }.to raise_error(Containers::StaticRangeIndex::InvalidRangeError)
    expect { index.kth(0, 5, 1) }.to raise_error(Containers::StaticRangeIndex::InvalidRangeError)
    expect { index.kth(3, 2, 1) }.to raise_error(Containers::StaticRangeIndex::InvalidRangeError)
  end

  it 'supports an empty input array and empty query ranges' do
    empty_index = described_class.new([])

    expect { empty_index.kth(0, 0, 1) }.to raise_error(Containers::StaticRangeIndex::EmptyRangeError)
    expect(empty_index.count(0, 0, 0)).to eq(0)
    expect(empty_index.count_less(0, 0, 0)).to eq(0)
  end

  it 'matches sorted slices on random small ranges' do
    random = Random.new(20261002)
    random_values = Array.new(40) { random.rand(-6..6) }
    random_index = described_class.new(random_values)

    200.times do
      left = random.rand(0..random_values.size)
      right = random.rand(left..random_values.size)
      slice = random_values[left...right]

      unless slice.empty?
        (1..slice.size).each do |k|
          expect(random_index.kth(left, right, k)).to eq(slice.sort[k - 1])
        end
      end

      (-8..8).each do |threshold|
        expect(random_index.count(threshold, left, right)).to eq(slice.count(threshold))
        expect(random_index.count_less(threshold, left, right)).to eq(slice.count { |value| value < threshold })
      end
    end
  end

  it 'exposes measured persistent-tree node and byte growth' do
    growing_index = described_class.new((1..100).to_a)

    expect(growing_index.index_nodes).to be > 100
    expect(growing_index.index_bytes).to be > growing_index.size
  end
end
