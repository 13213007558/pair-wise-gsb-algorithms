$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe ::Containers::KLLSketch do
  let(:sketch) { Containers::KLLSketch.new }

  # Exact rank of +value+ in +data+: number of elements <= value.
  def exact_rank(data, value)
    data.count { |x| x <= value }
  end

  # Exact value at normalized rank q (rank q * (n - 1)) in +data+.
  def exact_quantile(sorted, q)
    sorted[(q * (sorted.size - 1)).ceil]
  end

  describe 'initialization' do
    it 'rejects a capacity below the minimum' do
      expect { Containers::KLLSketch.new(1) }.to raise_error(ArgumentError)
      expect { Containers::KLLSketch.new(2.5) }.to raise_error(ArgumentError)
    end

    it 'rejects a random source that is neither #rand-able nor callable' do
      expect { Containers::KLLSketch.new(10, random: 42) }.to raise_error(ArgumentError)
    end
  end

  describe 'empty sketch' do
    it 'reports size 0 and empty?' do
      expect(sketch.size).to eql(0)
      expect(sketch).to be_empty
    end

    it 'answers nil for quantiles and min/max' do
      expect(sketch.quantile(0)).to be_nil
      expect(sketch.quantile(0.5)).to be_nil
      expect(sketch.quantile(1)).to be_nil
      expect(sketch.min).to be_nil
      expect(sketch.max).to be_nil
    end

    it 'answers 0 for any rank' do
      expect(sketch.rank(10)).to eql(0)
    end
  end

  describe 'NaN handling' do
    it 'rejects NaN on add' do
      expect { sketch.add(Float::NAN) }.to raise_error(ArgumentError)
      expect(sketch.size).to eql(0)
    end

    it 'rejects NaN on quantile and rank' do
      sketch.add(1.0)
      expect { sketch.quantile(Float::NAN) }.to raise_error(ArgumentError)
      expect { sketch.rank(Float::NAN) }.to raise_error(ArgumentError)
    end
  end

  describe 'quantile argument validation' do
    it 'rejects q outside [0, 1]' do
      sketch.add(1)
      expect { sketch.quantile(-0.1) }.to raise_error(ArgumentError)
      expect { sketch.quantile(1.1) }.to raise_error(ArgumentError)
      expect { sketch.quantile('0.5') }.to raise_error(ArgumentError)
    end
  end

  describe 'without compression (all values retained)' do
    # k far above the number of added values, so nothing is ever compacted
    # and every answer must be exact.
    let(:data) { [5, 1, 9, 3, 7, 3, 3, 8, 0, 2] }
    let(:exact) { Containers::KLLSketch.new(1024, random: Random.new(1)) }

    before { data.each { |x| exact.add(x) } }

    it 'retains every value' do
      expect(exact.retained).to eql(data.size)
    end

    it 'answers exact quantiles, duplicates included' do
      sorted = data.sort
      [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1].each do |q|
        expect(exact.quantile(q)).to eql(exact_quantile(sorted, q))
      end
    end

    it 'answers exact ranks' do
      (0..10).each do |x|
        expect(exact.rank(x)).to eql(exact_rank(data, x))
      end
    end

    it 'tracks exact min and max' do
      expect(exact.min).to eql(data.min)
      expect(exact.max).to eql(data.max)
    end
  end

  describe 'duplicate values' do
    it 'handles heavy duplication, also under compression' do
      s = Containers::KLLSketch.new(8, random: Random.new(7))
      5_000.times { s.add(42) }
      100.times { |i| s.add(i) }
      expect(s.size).to eql(5_100)
      expect(s.quantile(0.5)).to eql(42)
      expect(s.quantile(0)).to eql(0)
      expect(s.quantile(1)).to eql(99)
      expect(s.rank(42)).to be_within(200).of(5_043)
    end
  end

  describe 'extreme tails' do
    it 'keeps exact min/max even with extreme magnitudes and compression' do
      s = Containers::KLLSketch.new(16, random: Random.new(3))
      extremes = [-1e308, -5e-324, 0.0, 5e-324, 1e308]
      10_000.times { |i| s.add(i - 5_000) }
      extremes.each { |x| s.add(x) }
      expect(s.min).to eql(-1e308)
      expect(s.max).to eql(1e308)
      expect(s.quantile(0)).to eql(-1e308)
      expect(s.quantile(1)).to eql(1e308)
    end
  end

  describe 'caller-supplied randomness' do
    it 'is reproducible for the same seed' do
      data = Array.new(20_000) { |i| (i * 7919) % 10_000 }
      a = Containers::KLLSketch.new(64, random: Random.new(99))
      b = Containers::KLLSketch.new(64, random: Random.new(99))
      data.each { |x| a.add(x); b.add(x) }
      [0.01, 0.5, 0.99].each do |q|
        expect(a.quantile(q)).to eql(b.quantile(q))
      end
    end

    it 'accepts a callable random source' do
      calls = 0
      coin = ->(n) { calls += 1; rand(n) }
      s = Containers::KLLSketch.new(4, random: coin)
      1_000.times { |i| s.add(i) }
      expect(s.size).to eql(1_000)
      expect(calls).to be > 0
    end
  end

  describe 'merge' do
    it 'merges sketches of different sizes into the union of both streams' do
      rng = Random.new(11)
      small = Containers::KLLSketch.new(1024, random: Random.new(1))
      big = Containers::KLLSketch.new(64, random: Random.new(2))
      small_data = Array.new(500) { rng.rand(1_000) }
      big_data = Array.new(50_000) { rng.rand(1_000) }
      small_data.each { |x| small.add(x) }
      big_data.each { |x| big.add(x) }

      expect(big.retained).to be < big.size # big one did compress
      big.merge(small)

      expect(big.size).to eql(50_500)
      combined = (small_data + big_data).sort
      expect(big.quantile(0)).to eql(combined.first)
      expect(big.quantile(1)).to eql(combined.last)
      median_rank = exact_rank(combined, big.quantile(0.5))
      expect(median_rank).to be_within(0.03 * combined.size).of(0.5 * (combined.size - 1))
    end

    it 'merging an empty sketch changes nothing' do
      s = Containers::KLLSketch.new(1024)
      [3, 1, 2].each { |x| s.add(x) }
      s.merge(Containers::KLLSketch.new)
      expect(s.size).to eql(3)
      expect(s.quantile(0.5)).to eql(2)
    end

    it 'merging into an empty sketch adopts the data' do
      s = Containers::KLLSketch.new(1024)
      other = Containers::KLLSketch.new(1024)
      [3, 1, 2].each { |x| other.add(x) }
      s.merge(other)
      expect(s.size).to eql(3)
      expect(s.quantile(0)).to eql(1)
      expect(s.quantile(1)).to eql(3)
    end

    it 'accepts a different capacity on the other sketch' do
      a = Containers::KLLSketch.new(8, random: Random.new(1))
      b = Containers::KLLSketch.new(256, random: Random.new(2))
      2_000.times { |i| a.add(i) }
      500.times { |i| b.add(i * 2) }
      a.merge(b)
      expect(a.size).to eql(2_500)
      expect(a.k).to eql(8)
    end

    it 'does not modify the other sketch' do
      a = Containers::KLLSketch.new(16, random: Random.new(1))
      b = Containers::KLLSketch.new(16, random: Random.new(2))
      1_000.times { |i| a.add(i); b.add(i * 3) }
      snapshot = b.quantile(0.5)
      retained = b.retained
      a.merge(b)
      expect(b.size).to eql(1_000)
      expect(b.retained).to eql(retained)
      expect(b.quantile(0.5)).to eql(snapshot)
    end

    it 'supports merging a sketch into itself' do
      s = Containers::KLLSketch.new(1024)
      [1, 2, 3].each { |x| s.add(x) }
      s.merge(s)
      expect(s.size).to eql(6)
      expect(s.rank(2)).to eql(4)
    end

    it 'rejects non-sketch arguments' do
      expect { sketch.merge([1, 2, 3]) }.to raise_error(ArgumentError)
    end
  end

  # The capacity parameter k bounds the *rank* error of the answers, not the
  # error in value units. These checks measure the observed rank error over a
  # fixed set of seeds: they demonstrate the statistical bound, they are NOT
  # a deterministic guarantee for any single run.
  describe 'rank error after compression (statistical, fixed seeds)' do
    n = 50_000
    seeds = [1, 2, 3, 4, 5]
    quantiles = (1..19).map { |i| i / 20.0 }
    data = Array.new(n) { |i| (i * 6_061 + 17) % 9_983 }.sort

    def build(k, seed, data)
      s = Containers::KLLSketch.new(k, random: Random.new(seed))
      data.each { |x| s.add(x) }
      s
    end

    it 'compresses to sub-linear space' do
      s = build(200, seeds.first, data)
      expect(s.retained).to be < s.size
      expect(s.retained).to be < 2_000
    end

    it 'keeps normalized rank error of quantile() within the k=200 bound for every seed' do
      seeds.each do |seed|
        s = build(200, seed, data)
        quantiles.each do |q|
          got_rank = exact_rank(data, s.quantile(q)) - 1
          error = (got_rank - q * (n - 1)).abs / n.to_f
          expect(error).to be <= 0.02,
            "seed #{seed}, q=#{q}: rank error #{error} exceeds 0.02"
        end
      end
    end

    it 'keeps normalized error of rank() within the k=200 bound for every seed' do
      probes = (1..19).map { |i| exact_quantile(data, i / 20.0) }
      seeds.each do |seed|
        s = build(200, seed, data)
        probes.each do |x|
          error = (s.rank(x) - exact_rank(data, x)).abs / n.to_f
          expect(error).to be <= 0.02,
            "seed #{seed}, x=#{x}: rank error #{error} exceeds 0.02"
        end
      end
    end

    it 'reduces average rank error when k grows' do
      average_error = lambda do |k|
        seeds.sum do |seed|
          s = build(k, seed, data)
          quantiles.sum do |q|
            ((exact_rank(data, s.quantile(q)) - 1) - q * (n - 1)).abs / n.to_f
          end
        end / (seeds.size * quantiles.size)
      end
      expect(average_error.call(400)).to be < average_error.call(50)
    end
  end
end

