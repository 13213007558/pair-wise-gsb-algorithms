$LOAD_PATH << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Algorithms::IBLT do
  def build(ids, options = {})
    iblt = described_class.new(**{ table_size: 64, hash_count: 3 }.merge(options))
    ids.each { |id| iblt.insert(id) }
    iblt
  end

  it 'recovers IDs that appear only on each side' do
    left = build([1, 2, 3, 100, 200])
    right = build([2, 100, 300])

    result = left.recover(right)

    expect(result).to be_complete
    expect(result).not_to be_incomplete
    expect(result.left_only).to eq([1, 3, 200])
    expect(result.right_only).to eq([300])
    expect(result.residual).to eq([])
  end

  it 'distinguishes complete decoding with no difference from incomplete decoding' do
    left = build([1, 2, 3])
    right = build([3, 1, 2])

    result = (left - right).decode

    expect(result).to be_complete
    expect(result).to be_identical
    expect(result).to be_no_difference
    expect(result).not_to be_partially_recovered
    expect(result.left_only).to eq([])
    expect(result.right_only).to eq([])
  end

  it 'uses set semantics for duplicate insertions into one summary' do
    left = build([1, 1, 1, 2])
    right = build([2])

    result = (left - right).decode

    expect(result).to be_complete
    expect(result.left_only).to eq([1])
    expect(result.right_only).to eq([])
  end

  it 'does not mutate either summary during subtraction' do
    left = build([1, 2])
    right = build([2, 3])

    difference = left - right
    first = difference.decode
    second = difference.decode

    expect(first.status).to eq(:complete)
    expect(second.status).to eq(:complete)
    expect((left - right).decode.left_only).to eq([1])
  end

  it 'works with summaries exchanged as JSON' do
    left = build([1, 2, 3])
    right = Algorithms::IBLT.from_json(build([2, 3, 4]).to_json)

    result = (left - right).decode

    expect(result).to be_complete
    expect(result.left_only).to eq([1])
    expect(result.right_only).to eq([4])
  end

  it 'supports fixed-width unsigned IDs larger than 64 bits' do
    left = build([2 ** 100, (2 ** 100) + 5], table_size: 64, key_bytes: 16)
    right = build([2 ** 100], table_size: 64, key_bytes: 16)

    result = (left - right).decode

    expect(result).to be_complete
    expect(result.left_only).to eq([(2 ** 100) + 5])
  end

  it 'does not allow inserting into received or derived summaries' do
    received = described_class.from_json(build([1]).to_json)
    derived = build([1]) - build([])

    expect { received.insert(2) }.to raise_error(Algorithms::IBLT::Error, /received or derived/)
    expect { derived.insert(2) }.to raise_error(Algorithms::IBLT::Error, /received or derived/)
  end

  it 'rejects serialized summaries with an unexpected table size or cell range' do
    payload = JSON.parse(build([1]).to_json)
    payload["table_size"] += 1

    expect { described_class.from_h(payload) }.to raise_error(Algorithms::IBLT::Error, /exactly table_size/)

    payload = JSON.parse(build([1]).to_json)
    payload["cells"][0][1] = 2 ** 64

    expect { described_class.from_h(payload) }.to raise_error(Algorithms::IBLT::Error, /out-of-range/)
  end

  it 'rejects combining summaries with mismatched parameters' do
    left = build([1], table_size: 32)
    right = build([1], table_size: 64)

    expect { left.difference(right) }.to raise_error(ArgumentError, /different parameters/)
  end

  it 'rejects IDs outside the fixed unsigned width' do
    iblt = build([], key_bytes: 1)

    expect { iblt.insert(256) }.to raise_error(ArgumentError, /unsigned 1-byte/)
    expect { iblt.insert(-1) }.to raise_error(ArgumentError, /unsigned 1-byte/)
  end

  it 'returns partial recovery and residual cells when peeling stops' do
    left = described_class.new(table_size: 4, hash_count: 1, key_bytes: 1)
    right = described_class.new(table_size: 4, hash_count: 1, key_bytes: 1)
    left.insert(4)
    difference = left - right
    cells = Array.new(4) { Algorithms::IBLT::Cell.new(0, 0, 0) }
    recoverable_index = difference.positions_for(4).first
    residual_index = (recoverable_index + 1) % 4
    cells[recoverable_index] = Algorithms::IBLT::Cell.new(
      1,
      4,
      difference.send(:checksum_for, 4)
    )
    cells[residual_index] = Algorithms::IBLT::Cell.new(2, 5, difference.send(:checksum_for, 5))
    difference.send(:cells).replace(cells)

    result = difference.decode

    expect(result).to be_incomplete
    expect(result).not_to be_complete
    expect(result).not_to be_identical
    expect(result).to be_partially_recovered
    expect(result.left_only).to eq([4])
    expect(result.residual).not_to be_empty
    expect(result.residual.first).to be_a(Algorithms::IBLT::ResidualCell)
  end

  it 'keeps key sums and checksums within their fixed unsigned widths' do
    maximum = (2 ** 64) - 1
    left = build([maximum, maximum - 1])
    right = build([maximum - 1])

    result = (left - right).decode

    expect(result).to be_complete
    expect(result.left_only).to eq([maximum])
  end
end
