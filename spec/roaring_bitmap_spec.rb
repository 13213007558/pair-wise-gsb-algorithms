$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::RoaringBitmap do
  let(:bitmap) { Containers::RoaringBitmap.new }

  describe 'basic operations' do
    it 'starts empty' do
      expect(bitmap).to be_empty
      expect(bitmap.cardinality).to eql(0)
      expect(bitmap.to_a).to eql([])
    end

    it 'adds, queries and deletes values' do
      bitmap.add(5).add(1).add(100_000)
      expect(bitmap.include?(1)).to be true
      expect(bitmap.include?(5)).to be true
      expect(bitmap.include?(100_000)).to be true
      expect(bitmap.include?(2)).to be false
      expect(bitmap.cardinality).to eql(3)

      bitmap.delete(5)
      expect(bitmap.include?(5)).to be false
      expect(bitmap.cardinality).to eql(2)
      bitmap.delete(5) # no-op
      expect(bitmap.cardinality).to eql(2)
    end

    it 'ignores duplicate adds' do
      3.times { bitmap << 42 }
      expect(bitmap.cardinality).to eql(1)
    end

    it 'drops containers that become empty' do
      bitmap.add(1).add(65_536).delete(1)
      expect(bitmap.container_types.size).to eql(1)
      bitmap.delete(65_536)
      expect(bitmap).to be_empty
    end

    it 'iterates in ascending order across chunks' do
      values = [100_000, 3, 65_536, 0, 2**32 - 1]
      values.each { |v| bitmap << v }
      expect(bitmap.to_a).to eql(values.sort)
      expect(bitmap.map { |v| v }).to eql(values.sort)
      expect(bitmap.min).to eql(0)
      expect(bitmap.max).to eql(2**32 - 1)
    end
  end

  describe 'uint32 input validation' do
    it 'accepts the boundary values 0 and 2**32-1' do
      bitmap.add(0).add(2**32 - 1)
      expect(bitmap.include?(0)).to be true
      expect(bitmap.include?(2**32 - 1)).to be true
      expect(bitmap.rank(2**32 - 1)).to eql(2)
    end

    it 'rejects out-of-range values' do
      [-1, 2**32, 2**64].each do |bad|
        expect { bitmap.add(bad) }.to raise_error(RangeError)
        expect { bitmap.delete(bad) }.to raise_error(RangeError)
        expect { bitmap.include?(bad) }.to raise_error(RangeError)
        expect { bitmap.rank(bad) }.to raise_error(RangeError)
      end
    end

    it 'rejects non-integer values' do
      ['1', 1.5, nil, :sym].each do |bad|
        expect { bitmap.add(bad) }.to raise_error(TypeError)
        expect { bitmap.delete(bad) }.to raise_error(TypeError)
        expect { bitmap.include?(bad) }.to raise_error(TypeError)
        expect { bitmap.rank(bad) }.to raise_error(TypeError)
      end
      expect { bitmap.select('0') }.to raise_error(TypeError)
    end
  end

  describe 'container transitions' do
    it 'uses an array container while sparse' do
      bitmap.add(7)
      expect(bitmap.container_types).to eql([:array])
    end

    it 'switches to a bitmap container past 4096 values' do
      (0..4096).each { |v| bitmap << v }
      expect(bitmap.container_types).to eql([:bitmap])
      expect(bitmap.cardinality).to eql(4097)
    end

    it 'switches back to an array container when deletes make it sparse' do
      (0..4096).each { |v| bitmap << v }
      bitmap.delete(4096)
      expect(bitmap.container_types).to eql([:array])
      expect(bitmap.cardinality).to eql(4096)
    end

    it 'switches to a run container after run_optimize on contiguous ranges' do
      (0..999).each { |v| bitmap << v }
      expect(bitmap.container_types).to eql([:array])
      bitmap.run_optimize
      expect(bitmap.container_types).to eql([:run])
      expect(bitmap.to_a).to eql((0..999).to_a)
    end

    it 'keeps fragmented data in array/bitmap containers after run_optimize' do
      (0..99).each { |v| bitmap << (v * 2) }
      bitmap.run_optimize
      expect(bitmap.container_types).to eql([:array])
    end

    it 'expands adjacent runs in place and merges bridging values' do
      (0..9).each { |v| bitmap << v }
      bitmap.run_optimize
      bitmap.add(10).add(20)
      expect(bitmap.container_types).to eql([:run])
      (11..19).each { |v| bitmap << v }
      expect(bitmap.container_types).to eql([:run])
      expect(bitmap.to_a).to eql((0..20).to_a)
    end

    it 'returns a run container to a sparse array when deletes fragment it' do
      (0..99).each { |v| bitmap << v }
      bitmap.run_optimize
      expect(bitmap.container_types).to eql([:run])
      (1..99).step(2).each { |v| bitmap.delete(v) }
      expect(bitmap.container_types).to eql([:array])
      expect(bitmap.to_a).to eql((0..98).step(2).to_a)
    end
  end

  describe 'set operations' do
    let(:a) { Containers::RoaringBitmap.new((1..5000).to_a) }
    let(:b) { Containers::RoaringBitmap.new((2500..7500).to_a) }

    it 'computes intersection' do
      expect((a & b).to_a).to eql((2500..5000).to_a)
      expect(a.intersection(b)).to eq(a & b)
    end

    it 'computes union' do
      expect((a | b).to_a).to eql((1..7500).to_a)
      expect(a.union(b)).to eq(a | b)
    end

    it 'computes difference' do
      expect((a - b).to_a).to eql((1..2499).to_a)
      expect(a.difference(b)).to eq(a - b)
    end

    it 'works across chunks and with run containers' do
      x = Containers::RoaringBitmap.new((0..99).to_a + [200_000, 200_001])
      y = Containers::RoaringBitmap.new((50..149).to_a + [200_001])
      x.run_optimize
      y.run_optimize
      expect((x & y).to_a).to eql((50..99).to_a + [200_001])
      expect((x | y).to_a).to eql((0..149).to_a + [200_000, 200_001])
      expect((x - y).to_a).to eql((0..49).to_a + [200_000])
      expect((y - x).to_a).to eql((100..149).to_a)
    end

    it 'rejects non-bitmap arguments' do
      expect { a | [1, 2] }.to raise_error(ArgumentError)
    end
  end

  describe 'rank and select' do
    let(:bitmap) do
      Containers::RoaringBitmap.new([5, 10, 15, 65_543, 2**32 - 1])
    end

    it 'ranks the number of values <= the argument' do
      expect(bitmap.rank(4)).to eql(0)
      expect(bitmap.rank(5)).to eql(1)
      expect(bitmap.rank(12)).to eql(2)
      expect(bitmap.rank(65_543)).to eql(4)
      expect(bitmap.rank(2**32 - 1)).to eql(5)
    end

    it 'selects the i-th smallest value (0-based)' do
      expect(bitmap.select(0)).to eql(5)
      expect(bitmap.select(3)).to eql(65_543)
      expect(bitmap.select(4)).to eql(2**32 - 1)
      expect(bitmap.select(5)).to be_nil
      expect(bitmap.select(-1)).to be_nil
    end

    it 'is consistent on bitmap and run containers' do
      dense = Containers::RoaringBitmap.new((0..4999).to_a)
      expect(dense.container_types).to eql([:bitmap])
      expect(dense.rank(1234)).to eql(1235)
      expect(dense.select(1234)).to eql(1234)

      dense.run_optimize
      expect(dense.container_types).to eql([:run])
      expect(dense.rank(1234)).to eql(1235)
      expect(dense.select(1234)).to eql(1234)
    end
  end

  describe 'portable serialization' do
    # Hand-computed vectors following the CRoaring portable format.
    let(:array_bytes) do
      # cookie 12346, 1 container, key 0, card 3, offset 16, values 1,2,3
      [0x3A, 0x30, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 16, 0, 0, 0, 1, 0, 2, 0, 3, 0].pack('C*')
    end
    let(:run_bytes) do
      # cookie 12347, 1 container, run flag set, key 0, card 10, no offsets,
      # 1 run: value 0, length 9
      [0x3B, 0x30, 0, 0, 0, 0, 0, 0, 1, 0, 0, 9, 0, 1, 0, 0, 0, 9, 0].pack('C*')
    end
    let(:bitmap_bytes) do
      # cookie 12346, 1 container, key 0, card 5000, offset 16, bits 0..4999
      [0x3A, 0x30, 0, 0, 0, 0, 0, 0, 0, 0, 0x87, 0x13, 16, 0, 0, 0].pack('C*') +
        ("\xFF".b * 625) + ("\x00".b * (8192 - 625))
    end
    let(:empty_bytes) do
      # cookie 12346, size-1 == 0xFFFFFFFF (no containers)
      [0x3A, 0x30, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF].pack('C*')
    end
    let(:two_chunk_bytes) do
      # cookie 12346, 2 array containers: key 0 -> {1}, key 1 -> {2}
      [0x3A, 0x30, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
       24, 0, 0, 0, 26, 0, 0, 0, 1, 0, 2, 0].pack('C*')
    end

    it 'serializes an array container to the expected bytes' do
      expect(Containers::RoaringBitmap.new([1, 2, 3]).serialize).to eql(array_bytes)
    end

    it 'serializes a run container to the expected bytes' do
      rb = Containers::RoaringBitmap.new((0..9).to_a)
      rb.run_optimize
      expect(rb.container_types).to eql([:run])
      expect(rb.serialize).to eql(run_bytes)
    end

    it 'serializes a bitmap container to the expected bytes' do
      rb = Containers::RoaringBitmap.new((0..4999).to_a)
      expect(rb.container_types).to eql([:bitmap])
      expect(rb.serialize).to eql(bitmap_bytes)
    end

    it 'serializes an empty bitmap to the expected bytes' do
      expect(bitmap.serialize).to eql(empty_bytes)
    end

    it 'serializes multiple chunks to the expected bytes' do
      expect(Containers::RoaringBitmap.new([1, 65_538]).serialize).to eql(two_chunk_bytes)
    end

    it 'deserializes the fixed vectors' do
      expect(Containers::RoaringBitmap.deserialize(array_bytes).to_a).to eql([1, 2, 3])
      expect(Containers::RoaringBitmap.deserialize(run_bytes).to_a).to eql((0..9).to_a)
      expect(Containers::RoaringBitmap.deserialize(bitmap_bytes).to_a).to eql((0..4999).to_a)
      expect(Containers::RoaringBitmap.deserialize(empty_bytes).to_a).to eql([])
      expect(Containers::RoaringBitmap.deserialize(two_chunk_bytes).to_a).to eql([1, 65_538])
    end

    it 'round-trips a mixed bitmap with run containers and offsets' do
      rb = Containers::RoaringBitmap.new
      (0..9).each { |v| rb << v }                         # run
      [65_537, 65_636, 65_736].each { |v| rb << v }       # array
      (0..9998).step(2).each { |v| rb << (131_072 + v) }  # bitmap
      (196_708..196_807).each { |v| rb << v }             # run
      rb.run_optimize
      expect(rb.container_types).to eql([:run, :array, :bitmap, :run])

      copy = Containers::RoaringBitmap.deserialize(rb.serialize)
      expect(copy).to eq(rb)
      expect(copy.container_types).to eql([:run, :array, :bitmap, :run])
    end

    it 'raises on malformed input' do
      expect { Containers::RoaringBitmap.deserialize([1, 2]) }.to raise_error(ArgumentError)
      expect { Containers::RoaringBitmap.deserialize('') }.to raise_error(Containers::RoaringBitmap::DeserializationError)
      expect { Containers::RoaringBitmap.deserialize([999].pack('V')) }.to raise_error(Containers::RoaringBitmap::DeserializationError)
      expect { Containers::RoaringBitmap.deserialize(array_bytes.byteslice(0, 10)) }.to raise_error(Containers::RoaringBitmap::DeserializationError)
    end
  end
end
