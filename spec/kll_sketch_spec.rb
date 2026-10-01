$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Containers::KLLSketch do
  describe "empty sketch" do
    it "is empty and reports zero count" do
      sketch = Containers::KLLSketch.new
      expect(sketch).to be_empty
      expect(sketch.n).to eql(0)
      expect(sketch.size).to eql(0)
      expect(sketch.num_retained).to eql(0)
    end

    it "returns nil for quantile, cdf, min and max" do
      sketch = Containers::KLLSketch.new
      expect(sketch.quantile(0.5)).to be_nil
      expect(sketch.quantile(0.0)).to be_nil
      expect(sketch.quantile(1.0)).to be_nil
      expect(sketch.cdf(42)).to be_nil
      expect(sketch.min).to be_nil
      expect(sketch.max).to be_nil
    end

    it "returns 0 for rank" do
      expect(Containers::KLLSketch.new.rank(42)).to eql(0)
    end
  end

  describe "input validation" do
    it "rejects NaN explicitly" do
      sketch = Containers::KLLSketch.new
      expect { sketch.add(Float::NAN) }.to raise_error(ArgumentError)
      expect { sketch << 0.0 / 0.0 }.to raise_error(ArgumentError)
      expect(sketch.n).to eql(0)
    end

    it "rejects invalid k" do
      expect { Containers::KLLSketch.new(k: 1) }.to raise_error(ArgumentError)
      expect { Containers::KLLSketch.new(k: 2.5) }.to raise_error(ArgumentError)
    end

    it "rejects a random source that cannot produce randomness" do
      expect { Containers::KLLSketch.new(random: Object.new) }.to raise_error(ArgumentError)
    end

    it "rejects out-of-range quantile ranks" do
      sketch = Containers::KLLSketch.new
      sketch.add(1)
      expect { sketch.quantile(-0.1) }.to raise_error(ArgumentError)
      expect { sketch.quantile(1.1) }.to raise_error(ArgumentError)
      expect { sketch.quantile(Float::NAN) }.to raise_error(ArgumentError)
    end
  end

  describe "uncompressed (exact) behaviour" do
    it "retains every value and answers exactly when n stays below capacity" do
      sketch = Containers::KLLSketch.new(k: 200, random: Random.new(1))
      values = (1..100).to_a.shuffle(random: Random.new(7))
      values.each { |v| sketch.add(v) }

      expect(sketch.num_retained).to eql(100)
      expect(sketch.quantile(0.0)).to eql(1)
      expect(sketch.quantile(0.25)).to eql(25)
      expect(sketch.quantile(0.5)).to eql(50)
      expect(sketch.quantile(0.99)).to eql(99)
      expect(sketch.quantile(1.0)).to eql(100)
      expect(sketch.rank(50)).to eql(50)
      expect(sketch.cdf(50)).to eql(0.5)
      expect(sketch.min).to eql(1)
      expect(sketch.max).to eql(100)
    end

    it "handles duplicate values exactly" do
      sketch = Containers::KLLSketch.new(k: 200, random: Random.new(2))
      50.times { sketch.add(3) }
      50.times { sketch.add(7) }

      expect(sketch.quantile(0.5)).to eql(3)
      expect(sketch.quantile(0.51)).to eql(7)
      expect(sketch.quantile(1.0)).to eql(7)
      expect(sketch.rank(3)).to eql(50)
      expect(sketch.cdf(5)).to eql(0.5)
    end
  end

  describe "compressed behaviour" do
    it "compacts and keeps exact min/max" do
      sketch = Containers::KLLSketch.new(k: 16, random: Random.new(3))
      rng = Random.new(11)
      5_000.times { sketch.add(rng.rand) }

      expect(sketch.num_retained).to be < 5_000
      expect(sketch.n).to eql(5_000)
    end

    it "handles heavy duplicates under compaction" do
      sketch = Containers::KLLSketch.new(k: 16, random: Random.new(4))
      rng = Random.new(12)
      10_000.times { sketch.add([1, 1, 1, 2, 3][rng.rand(5)]) }

      expect(sketch.n).to eql(10_000)
      expect(sketch.quantile(0.0)).to eql(1)
      expect(sketch.quantile(1.0)).to eql(3)
      median = sketch.quantile(0.5)
      expect([1, 2]).to include(median)
      expect(sketch.cdf(1)).to be_within(0.1).of(0.6)
    end

    it "tracks extreme tails exactly" do
      sketch = Containers::KLLSketch.new(k: 16, random: Random.new(5))
      rng = Random.new(13)
      5_000.times { sketch.add(rng.rand(-1000.0..1000.0)) }
      sketch.add(-1.0e300)
      sketch.add(1.0e300)
      sketch.add(1.0e-300)

      expect(sketch.min).to eql(-1.0e300)
      expect(sketch.max).to eql(1.0e300)
      expect(sketch.quantile(0.0)).to eql(-1.0e300)
      expect(sketch.quantile(1.0)).to eql(1.0e300)
      # the extreme value itself may be compacted away, so its estimated
      # cdf is only approximately zero
      expect(sketch.cdf(-1.0e300)).to be < 0.01
      expect(sketch.cdf(1.0e300)).to eql(1.0)
    end

    # The rank error of a KLL sketch is a probabilistic guarantee: it holds
    # with high probability over the sketch's internal random choices, not
    # deterministically. These examples therefore replay a fixed set of
    # seeds (so the test itself is reproducible) and check the observed
    # rank error against a generous statistical bound for each seed, plus a
    # tighter bound on the average across seeds. A single passing run is
    # not a deterministic guarantee; the bound only makes sense as a
    # statement over many random runs.
    describe "statistical rank error (fixed seed set)" do
      seeds = [7, 42, 1337, 2024, 31_337]
      n = 20_000
      k = 200
      # k = 200 gives roughly 1-2% normalized rank error with high
      # probability; 5% per seed and 2% on average leave ample headroom
      # while still catching a broken compaction (which errs by 20%+).
      per_seed_bound = 0.05
      mean_bound = 0.02

      before(:all) do
        @max_errors = seeds.map do |seed|
          rng = Random.new(seed)
          sketch = Containers::KLLSketch.new(k: k, random: Random.new(seed * 3 + 1))
          values = (1..n).to_a.shuffle(random: rng)
          values.each { |v| sketch.add(v) }
          raise "expected compaction to happen" unless sketch.num_retained < n

          worst = 0.0
          1.upto(99) do |i|
            phi = i / 100.0
            estimate = sketch.quantile(phi)
            true_rank = estimate # values are 1..n, so value == true rank
            worst = [worst, (true_rank - phi * n).abs / n].max
          end
          1.step(n - 1, 997) do |v|
            worst = [worst, (sketch.cdf(v) - v.to_f / n).abs].max
          end
          worst
        end
      end

      it "keeps the max rank error within the statistical bound for every seed" do
        @max_errors.each_with_index do |error, i|
          expect(error).to be < per_seed_bound,
            "seed #{seeds[i]} had normalized rank error #{error}"
        end
      end

      it "keeps the average rank error well below the per-run bound" do
        mean = @max_errors.sum / @max_errors.size
        expect(mean).to be < mean_bound
      end
    end

    it "is deterministic given the same caller-supplied random source" do
      build = lambda do
        sketch = Containers::KLLSketch.new(k: 32, random: Random.new(99))
        rng = Random.new(17)
        5_000.times { sketch.add(rng.rand(10_000)) }
        sketch
      end
      a = build.call
      b = build.call
      [0.01, 0.1, 0.5, 0.9, 0.99].each do |phi|
        expect(a.quantile(phi)).to eql(b.quantile(phi))
      end
    end
  end

  describe "merging" do
    it "merges sketches of very different sizes" do
      big = Containers::KLLSketch.new(k: 100, random: Random.new(21))
      rng = Random.new(31)
      20_000.times { big.add(rng.rand(1.0..1000.0)) }

      small = Containers::KLLSketch.new(k: 200, random: Random.new(22))
      37.times { |i| small.add(i.to_f) }

      merged = big.merge(small)
      expect(merged.n).to eql(20_037)
      expect(merged.min).to eql(0.0)
      expect(merged.max).to eql(big.max)
      expect(merged.quantile(0.0)).to eql(0.0)
      # small sketch was uncompressed, so its exact values survive the merge
      expect(merged.rank(36.0)).to be >= 37
      # originals are untouched by the non-destructive merge
      expect(big.n).to eql(20_000)
      expect(small.n).to eql(37)
    end

    it "merge! updates the receiver and returns self" do
      a = Containers::KLLSketch.new(k: 50, random: Random.new(41))
      b = Containers::KLLSketch.new(k: 50, random: Random.new(42))
      1_000.times { |i| a.add(i) }
      1_000.times { |i| b.add(i + 1_000) }

      result = a.merge!(b)
      expect(result).to equal(a)
      expect(a.n).to eql(2_000)
      expect(a.quantile(0.0)).to eql(0)
      expect(a.quantile(1.0)).to eql(1_999)
      expect(a.cdf(999.5)).to be_within(0.05).of(0.5)
    end

    it "treats merging an empty sketch as a no-op" do
      sketch = Containers::KLLSketch.new(k: 50, random: Random.new(51))
      100.times { |i| sketch.add(i) }
      before = sketch.quantile(0.5)

      sketch.merge!(Containers::KLLSketch.new)
      expect(sketch.n).to eql(100)
      expect(sketch.quantile(0.5)).to eql(before)
    end

    it "merges into an empty sketch" do
      empty = Containers::KLLSketch.new(k: 50, random: Random.new(61))
      other = Containers::KLLSketch.new(k: 50, random: Random.new(62))
      500.times { |i| other.add(i * 2) }

      merged = empty.merge(other)
      expect(merged.n).to eql(500)
      expect(merged.quantile(0.5)).to be_within(20).of(500)
      expect(merged.min).to eql(0)
      expect(merged.max).to eql(998)
    end

    it "merges sketches with different k, keeping the receiver's k" do
      a = Containers::KLLSketch.new(k: 64, random: Random.new(71))
      b = Containers::KLLSketch.new(k: 256, random: Random.new(72))
      rng = Random.new(73)
      3_000.times { a.add(rng.rand) }
      3_000.times { b.add(rng.rand) }

      merged = a.merge(b)
      expect(merged.k).to eql(64)
      expect(merged.n).to eql(6_000)
      expect(merged.cdf(0.5)).to be_within(0.05).of(0.5)
    end

    it "refuses to merge non-sketch objects" do
      sketch = Containers::KLLSketch.new
      expect { sketch.merge!([1, 2, 3]) }.to raise_error(TypeError)
    end
  end
end
