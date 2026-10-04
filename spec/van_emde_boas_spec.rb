$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe "empty van Emde Boas set" do
  before(:each) do
    @set = Containers::VanEmdeBoasSet.new(8)
  end

  it "is empty and reports no minimum or maximum" do
    expect(@set).to be_empty
    expect(@set.size).to eql(0)
    expect(@set.min).to be_nil
    expect(@set.max).to be_nil
  end

  it "returns nil for predecessor, successor, and missing deletion" do
    expect(@set.predecessor(10)).to be_nil
    expect(@set.successor(10)).to be_nil
    expect(@set.delete(10)).to be_nil
  end

  it "rejects keys outside the universe" do
    expect { @set.insert(-1) }.to raise_error(ArgumentError)
    expect { @set.insert(256) }.to raise_error(ArgumentError)
    expect { @set.predecessor(-1) }.to raise_error(ArgumentError)
    expect { @set.successor(256) }.to raise_error(ArgumentError)
  end

  it "rejects non-positive or non-integer bit widths" do
    expect { Containers::VanEmdeBoasSet.new(0) }.to raise_error(ArgumentError)
    expect { Containers::VanEmdeBoasSet.new(1.5) }.to raise_error(ArgumentError)
  end
end

describe "van Emde Boas set basics" do
  before(:each) do
    @set = Containers::VanEmdeBoasSet.new(8)
    [200, 5, 17, 99, 42].each { |key| @set.insert(key) }
  end

  it "ignores duplicate insertions" do
    @set.insert(42)
    @set << 42

    expect(@set.size).to eql(5)
    expect(@set.member?(42)).to be true
  end

  it "reports membership, bounds, predecessor, and successor" do
    expect(@set.member?(41)).to be false
    expect(@set.include?(42)).to be true
    expect(@set.min).to eql(5)
    expect(@set.max).to eql(200)
    expect(@set.predecessor(42)).to eql(17)
    expect(@set.successor(42)).to eql(99)
  end

  it "returns nil at ordered boundaries" do
    expect(@set.predecessor(5)).to be_nil
    expect(@set.successor(200)).to be_nil
  end

  it "deletes the current minimum and promotes its successor" do
    expect(@set.delete(5)).to eql(5)

    expect(@set.size).to eql(4)
    expect(@set.min).to eql(17)
    expect(@set.member?(5)).to be false
    expect(@set.predecessor(17)).to be_nil
  end

  it "deletes the last element in a cluster and clears that cluster" do
    set = Containers::VanEmdeBoasSet.new(8)
    set.insert(0)
    set.insert(16)
    before = set.node_count

    expect(set.delete(16)).to eql(16)

    expect(set.size).to eql(1)
    expect(set.min).to eql(0)
    expect(set.max).to eql(0)
    expect(set.node_count).to be < before
  end

  it "returns nil when deleting a missing key without changing size" do
    expect(@set.delete(43)).to be_nil
    expect(@set.size).to eql(5)
  end
end

describe "small van Emde Boas universe" do
  def neighbors(values, key)
    index = values.bsearch_index { |value| value >= key } || values.size
    predecessor = index.zero? ? nil : values[index - 1]
    successor = values[index] == key ? values[index + 1] : values[index]
    [predecessor, successor]
  end

  def assert_state(set, values, universe, context)
    raise "#{context}: size" unless set.size == values.size
    raise "#{context}: empty?" unless set.empty? == values.empty?
    raise "#{context}: min" unless set.min == values.first
    raise "#{context}: max" unless set.max == values.last

    universe.each do |key|
      expected_predecessor, expected_successor = neighbors(values, key)
      raise "#{context}: member(#{key})" unless set.member?(key) == values.include?(key)
      raise "#{context}: predecessor(#{key})" unless set.predecessor(key) == expected_predecessor
      raise "#{context}: successor(#{key})" unless set.successor(key) == expected_successor
    end
  end

  [1, 2, 3, 4].each do |bits|
    it "matches a sorted array for every subset and query in a #{bits}-bit universe" do
      universe = (0...(1 << bits)).to_a

      (0...(1 << universe.size)).each do |mask|
        values = universe.select { |key| mask & (1 << key) != 0 }
        set = Containers::VanEmdeBoasSet.new(bits)

        values.reverse_each { |key| set.insert(key) }
        values.each { |key| set.insert(key) }
        assert_state(set, values, universe, [bits, mask, :initial])

        if bits <= 3
          remaining = values.dup
          until remaining.empty?
            deleted = remaining.shift
            raise [bits, mask, :delete, deleted].inspect unless set.delete(deleted) == deleted
            assert_state(set, remaining, universe, [bits, mask, :delete_min])
          end
        else
          unless values.empty?
            set.delete(values.first)
            assert_state(set, values.drop(1), universe, [bits, mask, :delete_min])
            values.drop(1).each { |key| set.delete(key) }
          end

          maximum_set = Containers::VanEmdeBoasSet.new(bits)
          values.each { |key| maximum_set.insert(key) }
          unless values.empty?
            maximum_set.delete(values.last)
            assert_state(maximum_set, values[0...-1], universe, [bits, mask, :delete_max])
          end
        end

        raise [bits, mask, :cleanup].inspect unless set.empty? && set.node_count == 1
      end

      expect(:exhaustive).to eql(:exhaustive)
    end
  end

  it "matches a sorted array through randomized repeated updates" do
    random = Random.new(20261004)
    set = Containers::VanEmdeBoasSet.new(4)
    values = []

    2_000.times do |iteration|
      key = random.rand(16)

      if random.rand(3).zero?
        values << key unless values.include?(key)
        values.sort!
        set.insert(key)
      else
        values.delete(key)
        set.delete(key)
      end

      raise "iteration #{iteration}: size" unless set.size == values.size
      raise "iteration #{iteration}: min" unless set.min == values.first
      raise "iteration #{iteration}: max" unless set.max == values.last

      next unless iteration % 25 == 0

      (0...16).each do |query|
        expected_predecessor, expected_successor = neighbors(values, query)
        raise "iteration #{iteration}: predecessor" unless set.predecessor(query) == expected_predecessor
        raise "iteration #{iteration}: successor" unless set.successor(query) == expected_successor
      end
    end
  end
end

describe "large van Emde Boas universe" do
  it "allocates logarithmically many nodes instead of 2**bits entries" do
    bits = 1024
    set = Containers::VanEmdeBoasSet.new(bits)
    keys = [0, (1 << bits) - 1, 1, (1 << (bits / 2)) + 3]

    keys.each { |key| set.insert(key) }

    expect(set.node_count).to be < 100
    expect(set.node_count).to be < (1 << bits)

    keys.each { |key| set.delete(key) }

    expect(set.node_count).to eql(1)
  end
end
