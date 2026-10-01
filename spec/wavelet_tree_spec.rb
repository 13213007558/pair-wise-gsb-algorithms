$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe "empty wavelet tree" do
  it "should not initialize with an empty array" do
    expect { Containers::WaveletTree.new([]) }.to raise_error(ArgumentError)
  end
end

describe "wavelet tree of [3, -1, 3, 2]" do
  before(:each) do
    @tree = Containers::WaveletTree.new([3, -1, 3, 2])
  end

  it "should answer the documented example on [1, 4)" do
    expect(@tree.kth(1, 4, 2)).to eql(2)
    expect(@tree.count(1, 4, 3)).to eql(1)
  end

  it "should answer kth for every k on the full range" do
    expect((1..4).map { |k| @tree.kth(0, 4, k) }).to eql([-1, 2, 3, 3])
  end

  it "should count occurrences including duplicates and negatives" do
    expect(@tree.count(0, 4, 3)).to eql(2)
    expect(@tree.count(0, 4, -1)).to eql(1)
    expect(@tree.count(0, 4, 99)).to eql(0)
    expect(@tree.count(0, 2, 3)).to eql(1)
  end

  it "should count elements below a threshold" do
    expect(@tree.count_less_than(0, 4, 3)).to eql(2)
    expect(@tree.count_less_than(0, 4, 0)).to eql(1)
    expect(@tree.count_less_than(0, 4, -100)).to eql(0)
    expect(@tree.count_less_than(0, 4, 100)).to eql(4)
    expect(@tree.count_less_than(1, 4, 3)).to eql(2)
  end

  it "should distinguish an empty range from an out-of-range k" do
    expect { @tree.kth(2, 2, 1) }.to raise_error(ArgumentError)
    expect { @tree.count(3, 3, 3) }.to raise_error(ArgumentError)
    expect { @tree.count_less_than(0, 0, 5) }.to raise_error(ArgumentError)
    expect(@tree.kth(1, 4, 0)).to be_nil
    expect(@tree.kth(1, 4, 4)).to be_nil
    expect(@tree.kth(1, 4, -1)).to be_nil
  end

  it "should reject out-of-bounds ranges" do
    expect { @tree.kth(-1, 2, 1) }.to raise_error(ArgumentError)
    expect { @tree.kth(0, 5, 1) }.to raise_error(ArgumentError)
    expect { @tree.kth(3, 2, 1) }.to raise_error(ArgumentError)
  end
end

describe "wavelet tree edge cases" do
  it "should handle a single element" do
    tree = Containers::WaveletTree.new([-7])
    expect(tree.kth(0, 1, 1)).to eql(-7)
    expect(tree.kth(0, 1, 2)).to be_nil
    expect(tree.count(0, 1, -7)).to eql(1)
    expect(tree.count_less_than(0, 1, 0)).to eql(1)
  end

  it "should handle all-equal values" do
    tree = Containers::WaveletTree.new([5, 5, 5])
    expect(tree.kth(0, 3, 3)).to eql(5)
    expect(tree.count(0, 3, 5)).to eql(3)
    expect(tree.count_less_than(0, 3, 5)).to eql(0)
    expect(tree.count_less_than(0, 3, 6)).to eql(3)
  end
end

describe "wavelet tree against brute force" do
  it "should match sorted-slice results on random small ranges" do
    rng = Random.new(42)
    50.times do
      n = 1 + rng.rand(40)
      arr = Array.new(n) { rng.rand(-20..20) }
      tree = Containers::WaveletTree.new(arr)
      100.times do
        l = rng.rand(n)
        r = l + 1 + rng.rand(n - l)
        slice = arr[l...r]
        sorted = slice.sort
        k = 1 + rng.rand(r - l)
        expect(tree.kth(l, r, k)).to eql(sorted[k - 1])
        expect(tree.kth(l, r, r - l + 1)).to be_nil
        v = rng.rand(-22..22)
        expect(tree.count(l, r, v)).to eql(slice.count(v))
        x = rng.rand(-22..22)
        expect(tree.count_less_than(l, r, x)).to eql(slice.count { |e| e < x })
      end
    end
  end
end
