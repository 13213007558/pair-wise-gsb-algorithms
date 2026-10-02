$: << File.join(File.expand_path(File.dirname(__FILE__)), "..", "lib")
require "algorithms"
require "set"
require "stringio"

describe Containers::RoaringBitmap do
  Bitmap  = Containers::RoaringBitmap
  ArrayContainer   = Bitmap::ArrayContainer
  BitmapContainer  = Bitmap::BitmapContainer
  RunContainer     = Bitmap::RunContainer
  SerializationError = Bitmap::SerializationError

  def bucket(bitmap, high)
    bitmap.send(:buckets)[high]
  end

  def set_bucket(bitmap, high, container)
    bitmap.send(:buckets)[high] = container
  end

  describe "basic membership" do
    it "starts empty and tracks additions and deletions" do
      bitmap = described_class.new
      expect(bitmap).to be_empty
      bitmap.add(10).add(20)
      expect(bitmap.size).to eq(2)
      expect(bitmap).to include(10, 20)
      expect(bitmap).not_to include(11)
      bitmap.delete(10)
      expect(bitmap.to_a).to eq([20])
      expect { bitmap.delete(10) }.not_to raise_error
    end

    it "accepts an enumerable of initial ids" do
      bitmap = described_class.new([3, 1, 2])
      expect(bitmap.to_a).to eq([1, 2, 3])
    end

    it "supports << and chaining" do
      bitmap = described_class.new
      expect(bitmap << 5).to equal(bitmap)
      expect(bitmap).to include(5)
    end

    it "rejects non-32-bit unsigned ids" do
      expect { described_class.new.add(-1) }.to raise_error(ArgumentError)
      expect { described_class.new.add(2**32) }.to raise_error(ArgumentError)
      expect { described_class.new.delete(-1) }.to raise_error(ArgumentError)
      expect(described_class.new.include?(-1)).to be false
      expect(described_class.new.include?(2**32)).to be false
    end

    it "iterates in ascending order across the 65536 boundary" do
      ids = [65_535, 65_536, 0, 131_071, 131_072, 2**32 - 1]
      bitmap = described_class.new(ids)
      expect(bitmap.to_a).to eq(ids.sort)
      expect(bitmap.min).to eq(0)
      expect(bitmap.max).to eq(2**32 - 1)
      expect(bitmap.size).to eq(ids.size)
    end

    it "is Enumerable" do
      bitmap = described_class.new([1, 2, 3, 4])
      expect(bitmap.select(&:even?)).to eq([2, 4])
      expect(bitmap.map { |id| id + 1 }).to eq([2, 3, 4, 5])
    end
  end

  describe "container representation" do
    it "uses an array container for sparse buckets" do
      bitmap = described_class.new(Array.new(100) { |i| i * 10 })
      expect(bucket(bitmap, 0)).to be_a(ArrayContainer)
    end

    it "promotes an array container to a bitmap once 4097 values are present" do
      dense_ids = (0...9000).select(&:even?)
      bitmap = described_class.new(dense_ids)
      expect(bucket(bitmap, 0)).to be_a(BitmapContainer)
      expect(bitmap.size).to eq(4500)
    end

    it "demotes a bitmap container back to an array after deletions" do
      dense_ids = (0...9000).select(&:even?)
      bitmap = described_class.new(dense_ids)
      dense_ids[300..].each { |id| bitmap.delete(id) }
      expect(bucket(bitmap, 0)).to be_a(ArrayContainer)
      expect(bitmap.size).to eq(300)
    end

    it "uses a run container when runs are the smallest representation" do
      bitmap = described_class.new
      set_bucket(bitmap, 0, RunContainer.new([[0, 65_536]]))
      serialized = bitmap.serialize
      restored = described_class.deserialize(serialized)
      expect(bucket(restored, 0)).to be_a(RunContainer)
      expect(restored.size).to eq(65_536)
    end

    it "does not require callers to choose a representation" do
      # Only the top-level API is used; container types are observed, not selected.
      bitmap = described_class.new
      (0...65_536).each { |id| bitmap.add(id) }
      expect(bucket(bitmap, 0)).to be_a(RunContainer)
      expect(bitmap.to_a).to eq((0...65_536).to_a)
    end
  end

  describe "set operations" do
    let(:left)  { described_class.new([1, 2, 3, 65_535, 65_536, 100_000]) }
    let(:right) { described_class.new([2, 3, 4, 65_536, 70_000]) }

    it "computes union, intersection and difference" do
      expect((left | right).to_a).to eq([1, 2, 3, 4, 65_535, 65_536, 70_000, 100_000])
      expect((left & right).to_a).to eq([2, 3, 65_536])
      expect((left - right).to_a).to eq([1, 65_535, 100_000])
    end

    it "does not mutate operands of non-destructive operators" do
      left.to_a
      right.to_a
      expect { left | right }.not_to change { left.to_a }
      expect { left & right }.not_to change { left.to_a }
      expect { left - right }.not_to change { left.to_a }
      expect(left.to_a).to eq([1, 2, 3, 65_535, 65_536, 100_000])
      expect(right.to_a).to eq([2, 3, 4, 65_536, 70_000])
    end

    it "supports destructive variants" do
      a = described_class.new([1, 2, 3])
      expect(a.union!(described_class.new([3, 4]))).to equal(a)
      expect(a.to_a).to eq([1, 2, 3, 4])
      a.intersection!(described_class.new([2, 4, 5]))
      expect(a.to_a).to eq([2, 4])
      a.difference!(described_class.new([2]))
      expect(a.to_a).to eq([4])
    end

    it "returns independent containers from non-destructive operations" do
      left = described_class.new([1, 70_000])
      right = described_class.new([2])
      union = left | right
      union.add(3).delete(1)
      expect(left.to_a).to eq([1, 70_000])

      inter = described_class.new([1, 2]) & described_class.new([2, 3])
      inter.add(99)
      expect((described_class.new([1, 2]) & described_class.new([2, 3])).to_a).to eq([2])
    end

    it "recovers canonical types after a set operation shrinks a dense bucket" do
      dense = described_class.new
      set_bucket(dense, 0, BitmapContainer.new(Array.new(1024) { |i| i == 0 ? (2**64 - 1) : 0 }))
      sparse = described_class.new([0, 63])
      result = dense & sparse
      expect(bucket(result, 0)).to be_a(ArrayContainer)
      expect(result.to_a).to eq([0, 63])
    end

    it "collapses clustered union results into a run container" do
      a = described_class.new
      set_bucket(a, 0, RunContainer.new([[0, 10]]))
      b = described_class.new((10..19).to_a)
      result = a | b
      expect(bucket(result, 0)).to be_a(RunContainer)
      expect(result.to_a).to eq((0..19).to_a)
    end

    it "matches Ruby Set for random inputs" do
      srand(4242)
      200.times do
        left_ref = Set.new
        right_ref = Set.new
        left = described_class.new
        right = described_class.new
        rand(800).times do
          id = rand < 0.7 ? rand(200_000) : rand(2**32)
          left.add(id)
          left_ref.add(id)
        end
        rand(800).times do
          id = rand < 0.7 ? rand(200_000) : rand(2**32)
          right.add(id)
          right_ref.add(id)
        end
        expect((left | right).to_a).to eq((left_ref | right_ref).to_a.sort)
        expect((left & right).to_a).to eq((left_ref & right_ref).to_a.sort)
        expect((left - right).to_a).to eq((left_ref - right_ref).to_a.sort)
      end
    end
  end

  describe "serialization" do
    let(:ids) { [1, 2, 3, 65_535, 65_536, 65_537, 1_000_000, 2**32 - 1, 100, 101, 102] }

    it "round trips all ids" do
      bitmap = described_class.new(ids)
      restored = described_class.deserialize(bitmap.serialize)
      expect(restored).to eq(bitmap)
      expect(restored.to_a).to eq(ids.sort)
    end

    it "starts with a magic marker and an explicit version" do
      data = described_class.new([1]).serialize
      expect(data[0, 4]).to eq("RBMP".b)
      expect(data[4, 2].unpack1("n")).to eq(1)
    end

    it "produces identical bytes regardless of insertion order" do
      one = described_class.new(ids.shuffle)
      two = described_class.new(ids.shuffle)
      expect(one.serialize).to eq(two.serialize)
      expect(described_class.deserialize(one.serialize)).to eq(described_class.deserialize(two.serialize))
    end

    it "rejects every truncated prefix" do
      data = described_class.new(ids).serialize
      (0...data.bytesize).each do |cut|
        expect { described_class.deserialize(data[0, cut]) }.to raise_error(SerializationError)
      end
    end

    it "rejects trailing bytes" do
      data = described_class.new(ids).serialize
      expect { described_class.deserialize(data + "X") }.to raise_error(SerializationError)
    end

    it "rejects a bad magic marker" do
      data = described_class.new(ids).serialize
      bad = "XXXX".b + data[4..]
      expect { described_class.deserialize(bad) }.to raise_error(SerializationError)
    end

    it "rejects unknown versions" do
      data = described_class.new(ids).serialize.dup
      data[4] = [99].pack("C")
      expect { described_class.deserialize(data) }.to raise_error(SerializationError, /version/)
    end

    it "round trips through generic IO objects" do
      bitmap = described_class.new(ids)
      io = StringIO.new
      bitmap.serialize_to(io)
      io.rewind
      expect(described_class.deserialize_from(io)).to eq(bitmap)
    end

    it "rejects corrupted run payloads" do
      body = [2].pack("n") + [0, 9].pack("nn") + [5, 9].pack("nn")
      data = "RBMP\x00\x01\x00\x01".b + [0, Bitmap::TAG_RUN, body.bytesize].pack("nCN") + body
      expect { described_class.deserialize(data) }.to raise_error(SerializationError, /disjoint/)
    end

    it "rejects runs extending past the bucket" do
      body = [1].pack("n") + [65_535, 1].pack("nn")
      data = "RBMP\x00\x01\x00\x01".b + [0, Bitmap::TAG_RUN, body.bytesize].pack("nCN") + body
      expect { described_class.deserialize(data) }.to raise_error(SerializationError, /boundary/)
    end

    it "rejects an unknown container tag" do
      data = described_class.new([1]).serialize.dup
      data[10] = [9].pack("C")
      expect { described_class.deserialize(data) }.to raise_error(SerializationError, /tag/)
    end

    it "refuses bitmap containers that are sparse after decoding" do
      data = "RBMP\x00\x01\x00\x01".b +
             [0, Bitmap::TAG_BITMAP, Bitmap::BITMAP_BYTES].pack("nCN") +
             "\x00".b * Bitmap::BITMAP_BYTES
      expect { described_class.deserialize(data) }.to raise_error(SerializationError)
    end
  end

  describe "copy and equality" do
    it "produces independent deep copies" do
      original = described_class.new([1, 2, 65_536])
      copy = original.dup
      copy.add(3).delete(2)
      expect(original.to_a).to eq([1, 2, 65_536])
      expect(copy.to_a).to eq([1, 3, 65_536])
    end

    it "is value-equal for the same set built differently" do
      ids = [5, 10, 65_535, 65_536, 2**32 - 1]
      expect(described_class.new(ids.shuffle)).to eq(described_class.new(ids.shuffle))
    end

    it "clears all buckets" do
      bitmap = described_class.new([1, 65_536])
      bitmap.clear
      expect(bitmap).to be_empty
      expect(bitmap.serialize).to eq("RBMP\x00\x01\x00\x00".b)
    end
  end
end
