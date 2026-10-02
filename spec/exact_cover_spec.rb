$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'
require 'set'

describe Algorithms::SparseExactCover do
  def brute_force(rows, primary_columns, secondary_columns = [])
    ids = rows.keys
    primary = primary_columns.to_set
    allowed = (primary_columns + secondary_columns).to_set
    selectable_indexes = ids.each_index.select { |index|
      rows[ids[index]].any? { |column| primary.include?(column) }
    }

    selectable_indexes.reduce([[]]) do |subsets, index|
      subsets + subsets.map { |subset| subset + [index] }
    end.select do |subset|
      coverage = Hash.new(0)
      subset.each do |index|
        rows[ids[index]].each { |column| coverage[column] += 1 }
      end

      primary.all? { |column| coverage[column] == 1 } &&
        coverage.all? { |column, count| allowed.include?(column) &&
          (primary.include?(column) || count <= 1) }
    end.map do |subset|
      subset.map { |index| ids[index] }
    end
  end

  it "enumerates exact covers and returns original row IDs" do
    rows = { a: [1, :x], b: [2, :x], c: [1], d: [2] }
    cover = described_class.new(rows, [1, 2], [:x])

    expect(cover.to_a).to eq([[:a, :d], [:b, :c], [:c, :d]])
  end

  it "accepts array rows and Set columns" do
    rows = [["a", Set[1, "x"]], ["b", Set[2, "x"]], ["c", Set[1]], ["d", Set[2]]]
    cover = described_class.new(rows, primary_columns: [1, 2], secondary_columns: ["x"])

    expect(cover.solutions).to contain_exactly(["a", "d"], ["b", "c"], ["c", "d"])
  end

  it "accepts rows through keyword arguments" do
    rows = { a: [1], b: [1] }
    cover = described_class.new(candidates: rows, primary_columns: [1])

    expect(cover.solutions).to contain_exactly([:a], [:b])
  end

  it "returns one empty solution for an empty primary column set" do
    cover = described_class.new({ skip: [:x], unused: [:y] }, [], [:x, :y])

    expect(cover.to_a).to eq([[]])
  end

  it "returns no solutions when a primary column cannot be covered" do
    cover = described_class.new({ a: [1] }, [1, 2])

    expect(cover.to_a).to eq([])
  end

  it "does not repeat a secondary column while allowing it to be unused" do
    rows = { a: [1, :x], b: [2, :x], c: [1], d: [2] }
    cover = described_class.new(rows, [1, 2], [:x])

    expect(cover.to_a).not_to include([:a, :b])
    expect(cover.to_a).to include([:c, :d])
  end

  it "treats only secondary columns as optional conflicts" do
    cover = described_class.new(
      { one: [1, :x], two: [1, :y] },
      [1],
      [:x, :y]
    )

    expect(cover.to_a).to contain_exactly([:one], [:two])
  end

  it "rejects rows that cover the same column twice" do
    expect {
      described_class.new({ duplicate: [1, 1] }, [1])
    }.to raise_error(ArgumentError, /appears twice/)
  end

  it "restores search state after taking only some solutions" do
    rows = { a: [1, :x], b: [2, :x], c: [1], d: [2] }
    cover = described_class.new(rows, [1, 2], [:x])
    all_solutions = cover.to_a

    expect(cover.each.take(1)).to eq([[:a, :d]])
    expect(cover).not_to be_active
    expect(cover.to_a).to eq(all_solutions)

    collected = []
    cover.each do |solution|
      collected << solution
      break if collected.length == 2
    end
    expect(collected).to eq(all_solutions.first(2))
    expect(cover.to_a).to eq(all_solutions)
  end

  it "can be closed while paused and then enumerated again" do
    rows = { a: [1, :x], b: [2, :x], c: [1], d: [2] }
    cover = described_class.new(rows, primary_columns: [1, 2], secondary_columns: [:x])
    all_solutions = cover.to_a

    enumerator = cover.each
    expect(enumerator.next).to eq([:a, :d])
    expect(cover).to be_active
    expect(enumerator.next).to eq([:b, :c])
    enumerator.close

    expect(cover).not_to be_active
    expect(cover.to_a).to eq(all_solutions)
  end

  it "matches row-subset brute force on small sparse matrices" do
    srand(2468)

    30.times do
      rows = {}
      row_count = rand(0..6)
      row_count.times do |index|
        columns = (0...rand(1..4)).map { rand(6) }.uniq
        rows["row_#{index}"] = columns
      end

      secondary_columns = (0...2).select { rand(2).zero? }
      secondary_set = secondary_columns.to_set
      all_columns = rows.values.flatten.uniq
      primary_columns = all_columns.reject { |column| secondary_set.include?(column) }

      cover = described_class.new(rows, primary_columns, secondary_columns)
      expected = brute_force(rows, primary_columns, secondary_columns)

      expect(cover.to_a).to contain_exactly(*expected)
    end
  end
end
