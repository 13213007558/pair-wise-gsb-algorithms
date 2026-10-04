$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Algorithms::SpaceSaving do
  def exact_counts(events)
    events.each_with_object(Hash.new(0)) { |item, counts| counts[item] += 1 }
  end

  def expect_bounds_to_cover(summary, exact_counts, items = exact_counts.keys)
    items.each do |item|
      actual = exact_counts.fetch(item, 0)
      estimate = summary.estimate(item)
      error = summary.error(item)

      expect(actual).to be <= estimate
      expect(estimate - error).to be <= actual
      expect(error).to be <= estimate

      unless summary.candidate?(item)
        expect(estimate).to eq(summary.omission_bound)
        expect(error).to eq(summary.omission_bound)
      end
    end

    noncandidate_max = exact_counts.reject { |item, _| summary.candidate?(item) }.values.max || 0
    expect(noncandidate_max).to be <= summary.omission_bound
  end

  describe "initialization and updates" do
    it "requires a positive integer capacity" do
      expect { described_class.new(0) }.to raise_error(ArgumentError)
      expect { described_class.new(1.5) }.to raise_error(ArgumentError)
      expect { described_class.new(-1) }.to raise_error(ArgumentError)
    end

    it "reports exact counts before the summary is full" do
      summary = described_class.new(3)
      events = [:a, :a, :b]

      summary.update_all(events)
      exact = exact_counts(events)

      expect(summary).not_to be_full
      expect(summary.size).to eq(2)
      expect(summary.candidates).to contain_exactly(:a, :b)
      expect(summary.bounds(:a)).to eq([2, 0])
      expect(summary.bounds(:b)).to eq([1, 0])
      expect(summary.estimate(:missing)).to eq(0)
      expect(summary.error(:missing)).to eq(0)
      expect_bounds_to_cover(summary, exact, exact.keys + [:missing])
    end

    it "returns candidate records ordered by decreasing estimated count" do
      summary = described_class.new(2)
      summary.update_all([:a, :a, :a, :b, :c])

      candidates = summary.to_a

      expect(candidates.map(&:item)).to eq([:a, :c])
      expect(candidates.map(&:count)).to eq([3, 2])
      expect(candidates.map(&:error)).to eq([0, 1])
      expect(summary.map(&:item)).to eq([:a, :c])
    end

    it "supports the shovel operator" do
      summary = described_class.new(1)

      expect(summary << :a).to be(summary)
      expect(summary.estimate(:a)).to eq(1)
    end
  end

  describe "sudden hotspot changes" do
    it "replaces old candidates and preserves conservative bounds" do
      summary = described_class.new(2)
      initial = [:old] * 5 + [:a] * 2 + [:b]
      switched = []
      20.times do
        switched << :new_one
        switched << :new_two
      end
      events = initial + switched
      exact = exact_counts(events)

      summary.update_all(events)

      expect(summary.candidates).to eq([:new_one, :new_two])
      expect(summary.candidate?(:old)).to be(false)
      expect(summary.bounds(:new_one)).to eq([24, 5])
      expect(summary.bounds(:new_two)).to eq([24, 4])
      expect(summary.bounds(:old)).to eq([5, 5])
      expect(summary.omission_bound).to eq(5)
      expect_bounds_to_cover(summary, exact, exact.keys + [:never_seen])
    end
  end

  describe "merging summaries" do
    it "merges equal-capacity summaries without mutating the inputs" do
      capacity = 3
      left = described_class.new(capacity)
      right = described_class.new(capacity)
      left_events = [:a] * 40 + [:b] * 10 + [:c] * 5 + [:d] + [:e]
      right_events = [:b] * 30 + [:c] * 20 + [:d] * 15 + [:f] + [:g]

      left.update_all(left_events)
      right.update_all(right_events)
      merged = described_class.merge(left, right)
      exact = exact_counts(left_events + right_events)

      expect(merged.candidates).to eq([:a, :b, :c])
      expect(merged.to_a.map { |candidate| [candidate.item, candidate.count, candidate.error] }).to eq([
        [:a, 57, 17],
        [:b, 40, 0],
        [:c, 27, 7]
      ])
      expect(merged.total).to eq(left.total + right.total)
      expect(merged.size).to eq(3)
      expect(merged.omission_bound).to eq(27)
      expect_bounds_to_cover(merged, exact, exact.keys + [:missing])

      expect(left.candidates).to eq([:a, :b, :e])
      expect(right.candidates).to eq([:b, :c, :g])
      expect(left.total).to eq(57)
      expect(right.total).to eq(67)
    end

    it "does not merge invalid inputs or summaries with different capacities" do
      summary = described_class.new(2)

      expect { summary.merge!({}) }.to raise_error(ArgumentError)
      expect { summary.merge!(described_class.new(3)) }.to raise_error(ArgumentError)
    end

    it "keeps exact bounds when the merged summary still has free capacity" do
      capacity = 6
      left = described_class.new(capacity)
      right = described_class.new(capacity)
      left_events = [:a, :b]
      right_events = [:c, :d]

      merged = left.update_all(left_events).merge(right.update_all(right_events))
      exact = exact_counts(left_events + right_events)

      expect(merged.candidates).to contain_exactly(:a, :b, :c, :d)
      expect(merged.omission_bound).to eq(0)
      expect_bounds_to_cover(merged, exact, exact.keys + [:missing])
    end

    it "uses the minimum merged count when the union exactly fills capacity" do
      capacity = 4
      left = described_class.new(capacity)
      right = described_class.new(capacity)
      left_events = [:a, :b]
      right_events = [:c, :d]

      merged = left.update_all(left_events).merge(right.update_all(right_events))
      exact = exact_counts(left_events + right_events)

      expect(merged).to be_full
      expect(merged.candidates).to contain_exactly(:a, :b, :c, :d)
      expect(merged.omission_bound).to eq(1)
      expect_bounds_to_cover(merged, exact, exact.keys + [:missing])
    end
  end

  describe "randomized comparison against exact Hash counters" do
    it "covers every true frequency after updates and merging", :aggregate_failures do
      random = Random.new(20261004)

      20.times do
        capacity = random.rand(2..5)
        left = described_class.new(capacity)
        right = described_class.new(capacity)
        left_events = Array.new(random.rand(30..80)) { random.rand(8) }
        right_events = Array.new(random.rand(30..80)) { random.rand(12) }
        exact = exact_counts(left_events + right_events)

        left.update_all(left_events)
        right.update_all(right_events)
        merged = left.merge(right)

        expect_bounds_to_cover(left, exact_counts(left_events))
        expect_bounds_to_cover(right, exact_counts(right_events))
        expect_bounds_to_cover(merged, exact, exact.keys + [:missing])
        expect(merged.total).to eq(left_events.size + right_events.size)
        expect(merged.size).to be <= capacity
      end
    end
  end
end
