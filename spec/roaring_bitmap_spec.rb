$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::RoaringBitmap do
  MAX_UINT32 = (1 << 32) - 1

  def hex_bytes(*chunks)
    [chunks.join].pack("H*")
  end

  # Fixed portable-serialization vectors, computed by hand following the
  # RoaringBitmap portable format specification.
  let(:empty_bytes) { hex_bytes("3a300000", "00000000") }
  let(:array_bytes) do
    # cookie, size=2, (key=0, card-1=2), (key=1, card-1=0), offsets 24 and 30,
    # then container data: [1, 2, 3] and [5]
    hex_bytes("3a300000", "02000000", "0000", "0200", "0100", "0000", "18000000", "1e000000",
              "0100", "0200", "0300", "0500")
  end
  let(:run_bytes) do
    # run cookie (size=1), run bitmap 0x01, (key=0, card-1=9), no offsets,
    # then one run: start=0, length=9 (values 0..9)
    hex_bytes("3b300000", "01", "0000", "0900", "0100", "0000", "0900")
  end
  let(:bitmap_bytes) do
    # cookie, size=1, (key=0, card-1=4096), offset 16, then 1024 little-endian
    # words holding the values 0..4095 and 65535 (a bitmap container must
    # have a cardinality above 4096)
    words = Array.new(1024, 0)
    64.times { |i| words[i] = (1 << 64) - 1 }
    words[1023] = 1 << 63
    hex_bytes("3a300000", "01000000", "0000", "0010", "10000000") + words.pack("Q<*")
  end

  describe "basic operations" do
    it "starts empty" do
      rb = Containers::RoaringBitmap.new
      expect(rb.empty?).to be true
      expect(rb.size).to eql(0)
      expect(rb.cardinality).to eql(0)
      expect(rb.to_a).to eql([])
      expect(rb.include?(0)).to be false
      expect(rb.rank(100)).to eql(0)
      expect(rb.select(0)).to be_nil
    end

    it "adds, queries and removes values" do
      rb = Containers::RoaringBitmap.new
      rb.add(5)
      rb << 3 << 7
      expect(rb.include?(3)).to be true
      expect(rb.include?(5)).to be true
      expect(rb.include?(7)).to be true
      expect(rb.include?(4)).to be false
      expect(rb.size).to eql(3)

      rb.add(5) # duplicate
      expect(rb.size).to eql(3)

      rb.remove(5)
      expect(rb.include?(5)).to be false
      expect(rb.size).to eql(2)

      rb.remove(5) # already gone
      expect(rb.size).to eql(2)
      expect(rb.to_a).to eql([3, 7])
    end

    it "handles the uint32 boundaries" do
      rb = Containers::RoaringBitmap.new
      rb.add(0)
      rb.add(MAX_UINT32)
      expect(rb.include?(0)).to be true
      expect(rb.include?(MAX_UINT32)).to be true
      expect(rb.include?(MAX_UINT32 - 1)).to be false
      expect(rb.size).to eql(2)
      rb.remove(0)
      rb.remove(MAX_UINT32)
      expect(rb.empty?).to be true
    end

    it "can be built from an enumerable" do
      rb = Containers::RoaringBitmap.new([3, 1, 2, 2])
      expect(rb.to_a).to eql([1, 2, 3])
    end

    it "iterates in ascending order" do
      rb = Containers::RoaringBitmap.new
      [100, 1, 65536, 50, MAX_UINT32].each { |v| rb.add(v) }
      expect(rb.map { |v| v }).to eql([1, 50, 100, 65536, MAX_UINT32])
    end
  end

  describe "input validation" do
    it "rejects values outside the uint32 range" do
      rb = Containers::RoaringBitmap.new
      [-1, MAX_UINT32 + 1, 1.5, "42", nil, :sym].each do |bad|
        expect { rb.add(bad) }.to raise_error(ArgumentError)
        expect { rb.remove(bad) }.to raise_error(ArgumentError)
        expect { rb.include?(bad) }.to raise_error(ArgumentError)
        expect { rb.rank(bad) }.to raise_error(ArgumentError)
      end
    end

    it "validates select indexes" do
      rb = Containers::RoaringBitmap.new([1, 2, 3])
      expect { rb.select("0") }.to raise_error(ArgumentError)
      expect(rb.select(-1)).to be_nil
      expect(rb.select(3)).to be_nil
    end

    it "rejects non-bitmap arguments for set operations" do
      rb = Containers::RoaringBitmap.new
      expect { rb & [1] }.to raise_error(ArgumentError)
      expect { rb | nil }.to raise_error(ArgumentError)
      expect { rb - "x" }.to raise_error(ArgumentError)
    end
  end

  describe "container transitions" do
    it "stays an array for small sparse containers" do
      rb = Containers::RoaringBitmap.new((0...100).map { |i| i * 2 })
      expect(rb.container_types).to eql({ 0 => :array })
    end

    it "switches to a run container when a range grows dense" do
      rb = Containers::RoaringBitmap.new((0...50).map { |i| i * 2 })
      expect(rb.container_types[0]).to eql(:array)
      (0...50).each { |i| rb.add(i * 2 + 1) } # fill the gaps -> 0..99
      expect(rb.container_types[0]).to eql(:run)
      expect(rb.to_a).to eql((0..99).to_a)
    end

    it "switches from array to run when growing past the array limit" do
      rb = Containers::RoaringBitmap.new
      (0..4096).each { |i| rb.add(i) }
      expect(rb.container_types[0]).to eql(:run)
      expect(rb.size).to eql(4097)
    end

    it "switches to a bitmap container for dense scattered data" do
      rb = Containers::RoaringBitmap.new((0...5000).map { |i| i * 2 })
      expect(rb.container_types[0]).to eql(:bitmap)
      expect(rb.size).to eql(5000)
    end

    it "switches back to an array when a bitmap becomes sparse" do
      rb = Containers::RoaringBitmap.new((0...5000).map { |i| i * 2 })
      expect(rb.container_types[0]).to eql(:bitmap)
      (0...1000).each { |i| rb.remove(i * 2) } # 4000 values left
      expect(rb.container_types[0]).to eql(:array)
      expect(rb.size).to eql(4000)
      expect(rb.to_a).to eql((1000...5000).map { |i| i * 2 })
    end

    it "switches back to an array when a run container is shattered" do
      rb = Containers::RoaringBitmap.new((0..99).to_a)
      expect(rb.container_types[0]).to eql(:run)
      (0...50).each { |i| rb.remove(i * 2 + 1) } # leave the even numbers
      expect(rb.container_types[0]).to eql(:array)
      expect(rb.to_a).to eql((0...50).map { |i| i * 2 })
    end

    it "drops containers that become empty" do
      rb = Containers::RoaringBitmap.new([1, 65536])
      rb.remove(1)
      rb.remove(65536)
      expect(rb.container_types).to eql({})
      expect(rb.empty?).to be true
    end
  end

  describe "set operations" do
    let(:a_values) { (0...20000).step(3).to_a + (100000..100500).to_a + [MAX_UINT32] }
    let(:b_values) { (0...20000).step(5).to_a + (100200..100700).to_a + [0, MAX_UINT32] }
    let(:rb_a) { Containers::RoaringBitmap.new(a_values) }
    let(:rb_b) { Containers::RoaringBitmap.new(b_values) }

    it "computes intersections" do
      expect((rb_a & rb_b).to_a).to eql(a_values & b_values)
      expect(rb_a.intersection(rb_b).to_a).to eql(a_values & b_values)
    end

    it "computes unions" do
      expect((rb_a | rb_b).to_a).to eql((a_values | b_values).sort)
      expect(rb_a.union(rb_b).to_a).to eql((a_values | b_values).sort)
    end

    it "computes differences" do
      expect((rb_a - rb_b).to_a).to eql(a_values - b_values)
      expect(rb_a.difference(rb_b).to_a).to eql(a_values - b_values)
      expect((rb_b - rb_a).to_a).to eql(b_values - a_values)
    end

    it "handles empty and disjoint bitmaps" do
      empty = Containers::RoaringBitmap.new
      disjoint = Containers::RoaringBitmap.new([1, 3, 5])
      even = Containers::RoaringBitmap.new([0, 2, 4])
      expect((rb_a & empty).to_a).to eql([])
      expect((rb_a | empty).to_a).to eql(rb_a.to_a)
      expect((rb_a - empty).to_a).to eql(rb_a.to_a)
      expect((empty - rb_a).to_a).to eql([])
      expect((disjoint & even).to_a).to eql([])
      expect((disjoint | even).to_a).to eql([0, 1, 2, 3, 4, 5])
    end

    it "does not modify its operands" do
      before_a = rb_a.to_a
      before_b = rb_b.to_a
      rb_a & rb_b
      rb_a | rb_b
      rb_a - rb_b
      expect(rb_a.to_a).to eql(before_a)
      expect(rb_b.to_a).to eql(before_b)
    end
  end

  describe "rank and select" do
    let(:values) { [1, 3, 5, 65536, 65538, MAX_UINT32] }
    let(:rb) { Containers::RoaringBitmap.new(values) }

    it "ranks values across containers" do
      expect(rb.rank(0)).to eql(0)
      expect(rb.rank(1)).to eql(1)
      expect(rb.rank(4)).to eql(2)
      expect(rb.rank(5)).to eql(3)
      expect(rb.rank(65535)).to eql(3)
      expect(rb.rank(65536)).to eql(4)
      expect(rb.rank(65537)).to eql(4)
      expect(rb.rank(MAX_UINT32)).to eql(6)
    end

    it "selects the i-th smallest value" do
      values.each_with_index do |value, i|
        expect(rb.select(i)).to eql(value)
      end
      expect(rb.select(values.size)).to be_nil
    end

    it "ranks and selects inside dense containers" do
      dense = Containers::RoaringBitmap.new((0...5000).map { |i| i * 2 })
      expect(dense.container_types[0]).to eql(:bitmap)
      expect(dense.rank(0)).to eql(1)
      expect(dense.rank(9997)).to eql(4999)
      expect(dense.rank(9998)).to eql(5000)
      expect(dense.select(0)).to eql(0)
      expect(dense.select(4999)).to eql(9998)
    end

    it "ranks and selects inside run containers" do
      runs = Containers::RoaringBitmap.new((0..99).to_a + (200..299).to_a)
      expect(runs.container_types[0]).to eql(:run)
      expect(runs.rank(99)).to eql(100)
      expect(runs.rank(150)).to eql(100)
      expect(runs.rank(200)).to eql(101)
      expect(runs.select(100)).to eql(200)
      expect(runs.select(199)).to eql(299)
    end

    it "is consistent with the sorted values" do
      rb = Containers::RoaringBitmap.new((0...3000).map { |i| i * 7 })
      sorted = rb.to_a
      [0, 1, 100, 999, 5000, 20993, 30000].each do |probe|
        expect(rb.rank(probe)).to eql(sorted.count { |v| v <= probe })
      end
      sorted.each_with_index { |value, i| expect(rb.select(i)).to eql(value) }
    end
  end

  describe "portable serialization" do
    it "serializes an empty bitmap" do
      expect(Containers::RoaringBitmap.new.serialize).to eql(empty_bytes)
    end

    it "serializes array containers to the fixed vector" do
      rb = Containers::RoaringBitmap.new([1, 2, 3, 65541])
      expect(rb.serialize).to eql(array_bytes)
    end

    it "serializes a run container to the fixed vector" do
      rb = Containers::RoaringBitmap.new((0..9).to_a)
      expect(rb.container_types[0]).to eql(:run)
      expect(rb.serialize).to eql(run_bytes)
    end

    it "deserializes the fixed vectors" do
      expect(Containers::RoaringBitmap.deserialize(empty_bytes).to_a).to eql([])
      expect(Containers::RoaringBitmap.deserialize(array_bytes).to_a).to eql([1, 2, 3, 65541])
      expect(Containers::RoaringBitmap.deserialize(run_bytes).to_a).to eql((0..9).to_a)
      expect(Containers::RoaringBitmap.deserialize(bitmap_bytes).to_a).to eql((0..4095).to_a + [65535])
    end

    it "keeps the container types given by the stream" do
      rb = Containers::RoaringBitmap.deserialize(bitmap_bytes)
      expect(rb.container_types).to eql({ 0 => :bitmap })
      expect(rb.serialize).to eql(bitmap_bytes)
    end

    it "round-trips a mixed bitmap with run-container offsets" do
      values = (0..5000).to_a +                         # key 0 -> run
               (0...5001).map { |i| 65536 + i * 2 } +   # key 1 -> bitmap
               [131072, 131074, 131076, 131078, 131080] + # key 2 -> array
               [196608, 196610] +                       # key 3 -> array
               [MAX_UINT32]                             # key 65535 -> array
      rb = Containers::RoaringBitmap.new(values)
      expect(rb.container_types).to eql(
        { 0 => :run, 1 => :bitmap, 2 => :array, 3 => :array, 65535 => :array })
      bytes = rb.serialize
      copy = Containers::RoaringBitmap.deserialize(bytes)
      expect(copy).to eq(rb)
      expect(copy.to_a).to eql(values)
      expect(copy.serialize).to eql(bytes)
    end

    it "round-trips bitmaps without run containers" do
      rb = Containers::RoaringBitmap.new((0...9000).map { |i| i * 3 } + [MAX_UINT32])
      copy = Containers::RoaringBitmap.deserialize(rb.serialize)
      expect(copy).to eq(rb)
    end

    it "rejects invalid input" do
      expect { Containers::RoaringBitmap.deserialize(nil) }.to raise_error(ArgumentError)
      expect { Containers::RoaringBitmap.deserialize(42) }.to raise_error(ArgumentError)
      expect { Containers::RoaringBitmap.deserialize("") }.to raise_error(ArgumentError)
      expect { Containers::RoaringBitmap.deserialize(["ff303000"].pack("H*")) }.to raise_error(ArgumentError)
      expect { Containers::RoaringBitmap.deserialize(array_bytes[0..-2]) }.to raise_error(ArgumentError)
      expect { Containers::RoaringBitmap.deserialize(array_bytes + "\x00".b) }.to raise_error(ArgumentError)
    end
  end

  describe "equality and copying" do
    it "compares bitmaps by their values" do
      rb1 = Containers::RoaringBitmap.new([1, 2, 3])
      rb2 = Containers::RoaringBitmap.new([3, 2, 1])
      rb3 = Containers::RoaringBitmap.new([1, 2, 4])
      expect(rb1).to eq(rb2)
      expect(rb1).not_to eq(rb3)
      expect(rb1).not_to eq([1, 2, 3])
    end

    it "compares equal across container representations" do
      rb = Containers::RoaringBitmap.deserialize(bitmap_bytes)
      expect(rb).to eq(Containers::RoaringBitmap.new((0..4095).to_a + [65535]))
    end

    it "duplicates independently" do
      rb = Containers::RoaringBitmap.new((0..100).to_a)
      copy = rb.dup
      copy.add(1000)
      copy.remove(0)
      expect(rb.include?(1000)).to be false
      expect(rb.include?(0)).to be true
      expect(copy.include?(1000)).to be true
    end
  end
end
