$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe "IBLT set reconciliation" do
  def digest(ids, options = {})
    values = {:buckets => 200, :hash_count => 3, :seed => 1,
              :bit_width => 64}.merge(options)
    Algorithms::IBLT.new(values[:buckets], values[:hash_count], values[:seed],
                         values[:bit_width]).insert_all(ids)
  end

  it "recovers IDs present on only one side" do
    left = [101, 102, 103, 2048, 4096]
    right = [103, 104, 4096, 8192]

    result = (digest(left) - digest(right)).recover

    expect(result.status).to eql(:complete)
    expect(result.complete?).to be(true)
    expect(result.incomplete?).to be(false)
    expect(result.no_difference?).to be(false)
    expect(result.left_only).to eql([101, 102, 2048])
    expect(result.right_only).to eql([104, 8192])
    expect(result.residual).to be_empty
  end

  it "treats repeated IDs as set insertions and ignores them" do
    left = Algorithms::IBLT.new(200, 3)
    right = Algorithms::IBLT.new(200, 3)

    expect(left.insert(7)).to be(true)
    expect(left.insert(7)).to be(false)
    left.insert(8)
    right.insert_all([7, 7, 8, 9, 9])

    result = (left - right).recover

    expect(result.status).to eql(:complete)
    expect(result.left_only).to be_empty
    expect(result.right_only).to eql([9])
  end

  it "reports a separate no-difference state for equal sets" do
    result = (digest([1, 2, 3]) - digest([3, 2, 1])).recover

    expect(result.status).to eql(:no_difference)
    expect(result.no_difference?).to be(true)
    expect(result.complete?).to be(false)
    expect(result.incomplete?).to be(false)
    expect(result.recovered_any?).to be(false)
    expect(result.left_only).to be_empty
    expect(result.right_only).to be_empty
    expect(result.residual).to be_empty
  end

  it "rejects merging summaries with mismatched parameters" do
    pairs = [
      [Algorithms::IBLT.new(10, 3, 1), Algorithms::IBLT.new(11, 3, 1)],
      [Algorithms::IBLT.new(10, 3, 1), Algorithms::IBLT.new(10, 4, 1)],
      [Algorithms::IBLT.new(10, 3, 1), Algorithms::IBLT.new(10, 3, 2)],
      [Algorithms::IBLT.new(10, 3, 1, 32), Algorithms::IBLT.new(10, 3, 1, 64)]
    ]

    pairs.each do |left, right|
      expect { left - right }.to raise_error(Algorithms::IBLT::ParameterMismatch)
    end
    expect { digest([1]) - Object.new }.to raise_error(Algorithms::IBLT::ParameterMismatch)
  end

  it "returns an incomplete state and residual when peeling recovers some IDs" do
    left_ids = [3, 20, 37]
    right_ids = [7, 26, 45]
    left = digest(left_ids, :buckets => 2, :hash_count => 2, :seed => 43)
    right = digest(right_ids, :buckets => 2, :hash_count => 2, :seed => 43)

    result = (left - right).recover

    expect(result.status).to eql(:partial)
    expect(result.complete?).to be(false)
    expect(result.no_difference?).to be(false)
    expect(result.incomplete?).to be(true)
    expect(result.recovered_any?).to be(true)
    expect(result.left_only).to eql([37])
    expect(result.right_only).to be_empty
    expect(result.residual).not_to be_empty
    expect(result.residual.active_cells.size).to eql(1)
  end

  it "returns a failed state when peeling cannot start without claiming completion" do
    left = digest([3, 5, 7, 9], :buckets => 3, :hash_count => 2, :seed => 26)
    right = digest([4, 6, 8, 10], :buckets => 3, :hash_count => 2, :seed => 26)

    result = (left - right).recover

    expect(result.status).to eql(:failed)
    expect(result.incomplete?).to be(true)
    expect(result.complete?).to be(false)
    expect(result.recovered_any?).to be(false)
    expect(result.left_only).to be_empty
    expect(result.right_only).to be_empty
    expect(result.residual).not_to be_empty
    expect(result.residual.active_cells).not_to be_empty
  end

  it "supports fixed-width unsigned IDs and rejects out-of-range values" do
    expect { Algorithms::IBLT.new(10, 3).insert(-1) }.to raise_error(
      Algorithms::IBLT::InvalidID)
    expect { Algorithms::IBLT.new(10, 3).insert(2 ** 64) }.to raise_error(
      Algorithms::IBLT::InvalidID)
    expect { Algorithms::IBLT.new(10, 3, 0, 32).insert(2 ** 32) }.to raise_error(
      Algorithms::IBLT::InvalidID)

    left = Algorithms::IBLT.new(20, 3, 0, 8).insert_all([0, 255])
    right = Algorithms::IBLT.new(20, 3, 0, 8).insert_all([255, 128])
    result = (left - right).recover

    expect(result.status).to eql(:complete)
    expect(result.left_only).to eql([0])
    expect(result.right_only).to eql([128])
  end

  it "does not mutate either summary during subtraction or recovery" do
    left = digest([1, 2])
    right = digest([2, 3])
    left_before = left.cells
    right_before = right.cells
    difference = left - right

    expect(left.cells.all? { |cell| cell.count.zero? || cell.count >= 0 }).to be(true)
    expect(left.cells).to eql(left_before)
    expect(right.cells).to eql(right_before)
    expect(difference.cells).not_to eql(left.cells)

    difference.recover
    expect(difference.recover.status).to eql(:complete)
  end

  it "serializes only the compact summary and can restore it" do
    left = digest([1, 2, 3, 42])
    data = left.to_h
    expect(data.keys).to contain_exactly(:parameters, :cells)
    restored = Algorithms::IBLT.from_h(data)

    expect(restored.parameters).to eql(left.parameters)
    expect(restored.cells).to eql(left.cells)

    marshaled = Marshal.load(Marshal.dump(left))
    expect(marshaled.cells).to eql(left.cells)
  end
end
