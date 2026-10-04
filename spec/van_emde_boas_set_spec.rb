$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::VanEmdeBoasSet do
  def expect_to_match(set, expected)
    expect(set.size).to eql(expected.size)
    expect(set.empty?).to eql(expected.empty?)
    expect(set.min).to eql(expected.first)
    expect(set.max).to eql(expected.last)

    universe_size = 1 << set.bits
    universe_size.times do |key|
      expect(set.include?(key)).to eql(expected.include?(key))

      predecessor_index = expected.bsearch_index { |value| value >= key }
      if predecessor_index.nil?
        expected_predecessor = expected.last
      elsif predecessor_index.zero?
        expected_predecessor = nil
      else
        expected_predecessor = expected[predecessor_index - 1]
      end

      successor_index = expected.bsearch_index { |value| value > key }
      expected_successor = successor_index.nil? ? nil : expected[successor_index]

      expect(set.predecessor(key)).to eql(expected_predecessor)
      expect(set.successor(key)).to eql(expected_successor)
    end
  end

  (1..5).each do |bits|
    it "matches a sorted array for every subset of a #{bits}-bit universe" do
      universe_size = 1 << bits

      universe_size.times do |mask|
        values = universe_size.times.select { |key| mask[key] == 1 }
        set = described_class.new(bits)
        expected = []

        values.sort_by { |key| (key * 7 + 5) % universe_size }.each do |key|
          set.insert(key)
          expected << key
          expected.sort!
          expect_to_match(set, expected)
        end

        values.each do |key|
          expect(set.insert(key)).to be_nil
        end
        expect_to_match(set, expected)

        values.sort_by { |key| (key * 11 + 3) % universe_size }.each do |key|
          expect(set.delete(key)).to eql(key)
          expected.delete(key)
          expect(set.delete(key)).to be_nil
          expect_to_match(set, expected)
        end
      end
    end
  end

  it "ignores duplicate insertions without changing set state" do
    set = described_class.new(4)

    expect(set.insert(5)).to eql(5)
    expect(set.insert(5)).to be_nil
    expect(set.size).to eql(1)
    expect(set.include?(5)).to be true

    expect(set.delete(5)).to eql(5)
    expect(set).to be_empty
    expect(set.delete(5)).to be_nil
  end

  it "deletes successive minimum values correctly" do
    set = described_class.new(4)
    values = [13, 1, 7, 0, 9, 5, 15]
    values.each { |value| set.insert(value) }

    values.sort.each do |value|
      expect(set.min).to eql(value)
      expect(set.delete(value)).to eql(value)
    end

    expect(set).to be_empty
    expect(set.min).to be_nil
    expect(set.max).to be_nil
  end

  it "removes the last element of a cluster and its summary entry" do
    set = described_class.new(4)
    set.insert(1)
    set.insert(15)

    expect(set.node_count).to eql(3)
    expect(set.delete(15)).to eql(15)
    expect(set.node_count).to eql(1)
    expect(set.max).to eql(1)
    expect(set.successor(1)).to be_nil
  end

  it "allocates sparse nodes for a very large universe" do
    bits = 1024
    set = described_class.new(bits)
    maximum = (1 << bits) - 1

    expect(set.node_count).to eql(1)
    set.insert(0)
    expect(set.node_count).to eql(1)

    set.insert(maximum)
    expect(set.node_count).to eql(3)
    expect(set.node_count).to be < bits * bits
    expect(set.predecessor(maximum)).to eql(0)
    expect(set.successor(0)).to eql(maximum)

    set.delete(maximum)
    expect(set.node_count).to eql(1)
    expect(set.max).to eql(0)
  end

  it "keeps node counts independent of universe size with sparse keys" do
    bits = 1024
    set = described_class.new(bits)
    maximum = (1 << bits) - 1
    set.insert(0)
    set.insert(maximum)
    set.insert(1)

    expect(set.size).to eql(3)
    expect(set.node_count).to be < 50
    expect(set.successor(0)).to eql(1)
    expect(set.predecessor(maximum)).to eql(1)
  end

  it "rejects invalid bit widths and keys" do
    expect { described_class.new(0) }.to raise_error(ArgumentError)
    set = described_class.new(3)
    expect { set.insert(-1) }.to raise_error(ArgumentError)
    expect { set.insert(8) }.to raise_error(ArgumentError)
    expect { set.insert(1.5) }.to raise_error(ArgumentError)
  end
end
