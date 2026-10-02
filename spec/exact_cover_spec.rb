$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe "exact cover" do
  # Ground truth: enumerate every subset of rows and keep those covering
  # each primary column exactly once and each secondary column at most once.
  # Rows are generated to cover at least one primary column, matching
  # Algorithm X, which only ever selects a row to cover a primary column.
  def brute_force_solutions(primary_size, secondary_size, rows)
    total = primary_size + secondary_size
    solutions = []
    rows = rows.to_a
    (rows.size + 1).times do |k|
      rows.combination(k) do |combo|
        counts = Array.new(total, 0)
        combo.each { |(_id, cols)| cols.each { |c| counts[c] += 1 } }
        next unless counts[0, primary_size].all? { |n| n == 1 }
        next unless counts[primary_size, secondary_size].all? { |n| n <= 1 }
        solutions << combo.map(&:first).sort
      end
    end
    solutions.sort
  end

  def solved(primary_size, secondary_size, rows)
    cover = Algorithms::ExactCover.new(primary_size, secondary_size: secondary_size)
    rows.each { |id, cols| cover.add_row(id, cols) }
    cover.solutions.map { |solution| solution.sort }.sort
  end

  it "solves Knuth's classic example" do
    cover = Algorithms::ExactCover.new(7)
    cover.add_row(1, [2, 4, 5])
    cover.add_row(2, [0, 3, 6])
    cover.add_row(3, [1, 2, 5])
    cover.add_row(4, [0, 3])
    cover.add_row(5, [1, 6])
    cover.add_row(6, [3, 4, 6])
    expect(cover.solutions.map { |s| s.sort }).to eql([[1, 4, 5]])
  end

  it "returns the original row ids" do
    cover = Algorithms::ExactCover.new(2)
    cover.add_row("alpha", [0])
    cover.add_row("beta", [1])
    cover.add_row("gamma", [0, 1])
    expect(cover.solutions.map { |s| s.sort }.sort).to eql([["alpha", "beta"], ["gamma"]])
  end

  it "yields the empty selection once for an empty primary column set" do
    cover = Algorithms::ExactCover.new(0)
    cover.add_row(:unused, [])
    expect(cover.solutions.to_a).to eql([[]])
  end

  it "returns no solutions when the cover is impossible" do
    cover = Algorithms::ExactCover.new(2)
    cover.add_row(:a, [0])
    cover.add_row(:b, [0])
    expect(cover.solutions.to_a).to eql([])
  end

  it "treats secondary columns as optional but non-repeatable" do
    cover = Algorithms::ExactCover.new(1, secondary_size: 1)
    cover.add_row(:a, [0, 1])
    cover.add_row(:b, [0, 1])
    cover.add_row(:c, [0])
    expect(cover.solutions.map(&:sort)).to eql([[:a], [:b], [:c]])
  end

  it "resolves mutually conflicting secondary columns deterministically" do
    cover = Algorithms::ExactCover.new(2, secondary_size: 1)
    cover.add_row(:a, [0, 2])
    cover.add_row(:b, [1, 2])
    cover.add_row(:c, [0])
    cover.add_row(:d, [1])
    expect(cover.solutions.map { |s| s.sort }.sort).to eql([[:a, :d], [:b, :c], [:c, :d]])
  end

  it "cleans up after breaking out of enumeration and re-enumerates identically" do
    cover = Algorithms::ExactCover.new(3, secondary_size: 1)
    cover.add_row(1, [0, 3])
    cover.add_row(2, [1])
    cover.add_row(3, [2])
    cover.add_row(4, [0, 1])
    cover.add_row(5, [1, 2, 3])
    full = cover.solutions.to_a
    expect(full.size).to be > 1

    session = cover.solutions
    first = nil
    session.each { |solution| first = solution; break }
    expect(first).to eql(full.first)
    expect(session.to_a).to eql(full)

    expect(cover.solutions.take(2)).to eql(full.first(2))
    expect(cover.solutions.to_a).to eql(full)
  end

  it "reproduces the same solutions after pause and close" do
    cover = Algorithms::ExactCover.new(4, secondary_size: 2)
    rows = [[:a, [0, 4]], [:b, [1]], [:c, [2, 5]], [:d, [3]],
            [:e, [0, 1]], [:f, [2, 3]], [:g, [0, 2]]]
    rows.each { |id, cols| cover.add_row(id, cols) }

    session = cover.solutions
    paused = session.next_solution
    session.close

    fresh = cover.solutions.to_a
    expect(fresh.first).to eql(paused)
    expect(fresh).to eql(cover.solutions.to_a)
    expect(fresh).to eql(Algorithms::ExactCover.new(4, secondary_size: 2).tap { |c|
      rows.each { |id, cols| c.add_row(id, cols) }
    }.solutions.to_a)
  end

  it "rejects out-of-range column indices" do
    cover = Algorithms::ExactCover.new(2, secondary_size: 1)
    expect { cover.add_row(:bad, [3]) }.to raise_error(ArgumentError)
    expect { cover.add_row(:bad, [-1]) }.to raise_error(ArgumentError)
  end

  it "matches brute-force row-subset enumeration on small random matrices" do
    rng = Random.new(20261002)
    100.times do
      primary_size = rng.rand(1..5)
      secondary_size = rng.rand(0..3)
      total = primary_size + secondary_size
      rows = {}
      rng.rand(0..8).times do |i|
        cols = [rng.rand(primary_size)]
        cols.concat((0...total).select { rng.rand < 0.3 })
        cols.uniq!
        rows[i] = cols
      end
      expect(solved(primary_size, secondary_size, rows)).to(
        eql(brute_force_solutions(primary_size, secondary_size, rows)),
        "mismatch for primary=#{primary_size} secondary=#{secondary_size} rows=#{rows.inspect}"
      )
    end
  end
end
