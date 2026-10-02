$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::CompressedBitmap do
  subject(:bitmap) { described_class.new }

  dense_bitmap_ids = (0...8192).select(&:odd?)
  dense_bitmap_ids << 10_000

  it "adds and removes 32-bit unsigned ids" do
    bitmap.add(0)
    bitmap << 1
    bitmap << (2**32 - 1)
    expect(bitmap.include?(0)).to be(true)
    expect(bitmap.include?(1)).to be(true)
    expect(bitmap.include?(2**32 - 1)).to be(true)
    expect(bitmap.cardinality).to eq(3)

    expect(bitmap.delete(1)).to be(true)
    expect(bitmap.delete(1)).to be(false)
    expect(bitmap.include?(1)).to be(false)
    expect(bitmap.cardinality).to eq(2)
    expect(bitmap.to_a).to eq([0, 2**32 - 1])
  end

  it "accepts repeated ids from constructors and bulk insertion" do
    created = described_class[0, 0, 1, 1]
    created.add_all([1, 2, 2])

    expect(created.to_a).to eq([0, 1, 2])
    expect(created.cardinality).to eq(3)
  end

  it "accepts a single enumerable of ids" do
    created = described_class[[1, 65_536]]

    expect(created.to_a).to eq([1, 65_536])
    expect(described_class[[0]].to_a).to eq([0])
  end

  it "rejects ids outside the 32-bit unsigned range" do
    expect { bitmap.add(-1) }.to raise_error(ArgumentError)
    expect { bitmap.add(2**32) }.to raise_error(ArgumentError)
    expect { bitmap.add(1.5) }.to raise_error(ArgumentError)
    expect { bitmap.delete(-1) }.to raise_error(ArgumentError)
  end

  it "rejects bulk input that is not enumerable" do
    expect { described_class.new(nil) }.to raise_error(ArgumentError)
    expect { bitmap.add_all(1) }.to raise_error(ArgumentError)
  end

  it "traverses ids globally in sorted order" do
    [4_294_901_760, 100_000, 65_535, 65_536, 0, 1, 4_294_967_295].each { |id| bitmap.add(id) }

    collected = []
    bitmap.each { |id| collected << id }
    expect(collected).to eq([0, 1, 65_535, 65_536, 100_000, 4_294_901_760, 4_294_967_295])
    expect(bitmap.map { |id| id }).to eq(collected)
  end

  it "automatically uses array, bitmap, and run bucket representations" do
    sparse = described_class[0, 5]
    dense = described_class[*dense_bitmap_ids]
    full = described_class[*(0..65_535).to_a]

    expect(sparse.send(:buckets)[0].kind).to eq(:array)
    expect(dense.send(:buckets)[0].kind).to eq(:bitmap)
    expect(full.send(:buckets)[0].kind).to eq(:runs)
  end

  it "changes bucket representation after mutation" do
    changed = described_class.new
    threshold_ids = 0.step(8_188, 2).to_a
    changed.add_all(threshold_ids)
    expect(changed.send(:buckets)[0].kind).to eq(:array)
    changed.add_all([65_536])
    expect(changed.send(:buckets)[1].kind).to eq(:array)

    changed.add(8_190)
    changed.add(8_192)
    expect(changed.send(:buckets)[0].kind).to eq(:bitmap)

    sparse_run = described_class.new
    sparse_run.add(0)
    sparse_run.add(1)
    expect(sparse_run.send(:buckets)[0].kind).to eq(:array)

    dense = described_class[*(0..65_535).to_a]
    expect(dense.send(:buckets)[0].kind).to eq(:runs)

    holes_for_run = 5_000.step(10_000, 2).to_a
    dense = dense - described_class[*holes_for_run]
    expect(dense.send(:buckets)[0].kind).to eq(:bitmap)

    changed.delete(8_190)
    changed.delete(8_192)
    expect(changed.send(:buckets)[0].kind).to eq(:array)
  end

  it "computes union across bucket representations and the 65536 boundary" do
    first = described_class[65_535, 65_536, 70_000]
    second = described_class[0, 65_536, 70_001]
    result = first | second

    expect(result.to_a).to eq([0, 65_535, 65_536, 70_000, 70_001])
    expect(first.to_a).to eq([65_535, 65_536, 70_000])
    expect(second.to_a).to eq([0, 65_536, 70_001])
  end

  it "computes intersection and changes sparse results to arrays" do
    first = described_class[*dense_bitmap_ids, 100_000]
    second_values = (100..10_100).to_a
    second = described_class[*second_values, 100_001]

    result = first & second

    expected = second_values & dense_bitmap_ids
    expect(result.cardinality).to eq(expected.length)
    expect(result.to_a).to eq(expected)
    expect(result.send(:buckets)[0].kind).to eq(:array)
    expect(result.send(:buckets)[1]).to be_nil
  end

  it "computes difference and canonicalizes changed buckets" do
    full = described_class[*(0..65_535).to_a, 100_000]
    holes = 5_000.step(10_000, 2).to_a
    removed = described_class[1, *holes, 100_000]
    result = full - removed

    expect(result.include?(1)).to be(false)
    holes.each { |id| expect(result.include?(id)).to be(false) }
    expect(result.cardinality).to eq(65_536 - holes.length - 1)
    expect(result.send(:buckets)[0].kind).to eq(:bitmap)
    expect(result.send(:buckets)[1]).to be_nil
  end

  it "canonicalizes bucket representations across set operations" do
    bitmap_side = described_class[*(1...8192).select(&:odd?), 10_000]
    array_side = described_class[*0.step(8190, 2).to_a]

    scattered = (10_000...18_192).select(&:even?)
    bitmap_side_for_union = described_class[*scattered, 20_000]
    union = bitmap_side_for_union | array_side
    expect(union.send(:buckets)[0].kind).to eq(:bitmap)

    full = described_class[*(0..65_535).to_a]
    expect((full & full).send(:buckets)[0].kind).to eq(:runs)
    expect(full - full).to be_empty

    overlap_bitmap_ids = 0.step(8_188, 2).to_a + (1...2_000).select(&:odd?)
    overlap_bitmap = described_class[*overlap_bitmap_ids]
    expect(overlap_bitmap.send(:buckets)[0].kind).to eq(:bitmap)
    intersection = overlap_bitmap & array_side
    expect(intersection.send(:buckets)[0].kind).to eq(:array)

    difference = union - array_side
    expect(difference.send(:buckets)[0].kind).to eq(:bitmap)
    expect(difference.to_a).to eq(bitmap_side_for_union.to_a)
  end

  it "rejects set operations with non-bitmap arguments" do
    expect { bitmap | [] }.to raise_error(ArgumentError)
    expect { bitmap & [] }.to raise_error(ArgumentError)
    expect { bitmap - [] }.to raise_error(ArgumentError)
  end

  it "serializes with a version and restores identically regardless of insertion order" do
    ids = [0, 1, 65_535, 65_536, 131_071, 131_072, 4_294_967_295, 100_000]
    forward = described_class[*ids]
    backward = described_class[*ids.reverse]
    shuffled = described_class[*ids.shuffle(random: Random.new(123))]

    expect(forward.dump.byteslice(0, 4)).to eq("RBM\x01".b)
    expect(forward.dump).to eq(backward.dump)
    expect(forward.dump).to eq(shuffled.dump)

    [forward, backward, shuffled].each do |created|
      restored = described_class.load(created.dump)
      expect(restored).to eq(created)
      expect(restored.to_a).to eq(ids.sort)
      expect(restored.dump).to eq(created.dump)
    end
  end

  it "serializes every bucket representation" do
    sparse = described_class[0, 5, 65_536]
    dense = described_class[*dense_bitmap_ids]
    full = described_class[*(0..65_535).to_a]

    [sparse, dense, full].each do |created|
      restored = described_class.load(created.dump)
      expect(restored.to_a).to eq(created.to_a)
      expect(restored.dump).to eq(created.dump)
    end
  end

  it "serializes and restores an empty bitmap" do
    restored = described_class.load(bitmap.dump)

    expect(restored).to eq(bitmap)
    expect(restored.to_a).to eq([])
    expect(restored.cardinality).to eq(0)
  end

  it "rejects truncated headers and bucket payloads" do
    full = described_class[0, 1, 2].dump

    expect { described_class.load("") }.to raise_error(ArgumentError)
    expect { described_class.load(full.byteslice(0, 7)) }.to raise_error(ArgumentError)
    expect { described_class.load(full.byteslice(0, full.bytesize - 1)) }.to raise_error(ArgumentError)
  end

  it "rejects unknown versions, signatures, trailing data, and non-canonical buckets" do
    full = described_class[0, 1, 2].dump.dup
    bad_version = full.dup
    bad_version.setbyte(3, 2)
    bad_signature = full.dup
    bad_signature.setbyte(0, "X".ord)
    run_header = [described_class::TAG_RUNS, 1].pack("Cn")
    noncanonical = "RBM\x01".b + [1].pack("N") + [0].pack("n") + run_header + [0, 1].pack("n*")

    expect { described_class.load(bad_version) }.to raise_error(ArgumentError)
    expect { described_class.load(bad_signature) }.to raise_error(ArgumentError)
    expect { described_class.load(full + "x".b) }.to raise_error(ArgumentError)
    expect { described_class.load(noncanonical) }.to raise_error(ArgumentError)
  end

  it "rejects malformed bitmap and run payloads" do
    invalid_bitmap_tag = [described_class::TAG_BITMAP].pack("C") + "\0" * 10
    invalid_bitmap = "RBM\x01".b + [1].pack("N") + [0].pack("n") + invalid_bitmap_tag
    run_payload = [described_class::TAG_RUNS, 1].pack("Cn") + [0, 0].pack("n*")
    invalid_run = "RBM\x01".b + [1].pack("N") + [0].pack("n") + run_payload

    expect { described_class.load(invalid_bitmap) }.to raise_error(ArgumentError)
    expect { described_class.load(invalid_run) }.to raise_error(ArgumentError)
  end

  it "supports equality, emptiness, membership outside range, and enumerator behavior" do
    expect(bitmap).to be_empty
    expect(bitmap.each).to be_a(Enumerator)
    expect(bitmap.include?(-1)).to be(false)
    expect(bitmap.include?(2**32)).to be(false)
    expect(bitmap.include?(1.5)).to be(false)

    first = described_class[2, 1]
    second = described_class[1, 2]
    expect(first).to eq(second)
    expect(first.hash).to eq(second.hash)
  end
end
