$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

class String; include Algorithms::Search; end

describe "search algorithms" do
  it "should binary search sorted arrays" do
    n = 1000
    @rand_array = Array.new(n) { rand(n) }.sort
    
    expect(Algorithms::Search.binary_search(@rand_array, @rand_array.first)).to eql(@rand_array.first)
    expect(Algorithms::Search.binary_search(@rand_array, 999999)).to be_nil
    expect(Algorithms::Search.binary_search(@rand_array, nil)).to be_nil
  end
  
  it "should use kmp_search to find substrings it has" do
    string = "ABC ABCDAB ABCDABCDABDE"
    expect(Algorithms::Search.kmp_search(string, "ABCDABD")).to eql(15)
    expect(Algorithms::Search.kmp_search(string, "ABCDEF")).to be_nil
    expect(Algorithms::Search.kmp_search(string, nil)).to be_nil
    expect(Algorithms::Search.kmp_search(string, "")).to be_nil
    expect(Algorithms::Search.kmp_search(nil, "ABCD")).to be_nil
  end
  
  it "should let you include Search in String to enable instance methods" do
    expect("ABC ABCDAB ABCDABCDABDE".kmp_search("ABCDABD")).to eql(15)
  end

  it "builds an Aho-Corasick matcher for overlapping patterns" do
    matcher = Algorithms::Search::AhoCorasickMatcher.new([
      [10, "a"], [20, "aa"], [30, "aaa"]
    ])

    matches = matcher.feed("aaa").map(&:to_a)

    expect(matches).to eql([
      [10, 0, 1],
      [20, 0, 2], [10, 1, 2],
      [30, 0, 3], [20, 1, 3], [10, 2, 3]
    ])
  end

  it "keeps different IDs for duplicate patterns in construction order" do
    matcher = Algorithms::Search::AhoCorasickMatcher.new([
      [10, "ab"], [20, "ab"]
    ])

    matches = matcher.feed("ab").map(&:to_a)

    expect(matches).to eql([[10, 0, 2], [20, 0, 2]])
  end

  it "finds shared-prefix, shared-suffix, and cross-chunk matches" do
    matcher = Algorithms::Search::AhoCorasickMatcher.new([
      [1, "he"], [2, "she"], [3, "his"], [4, "hers"]
    ])

    expect(matcher.feed("us")).to be_empty
    expect(matcher.feed("he").map(&:to_a)).to eql([[2, 1, 4], [1, 2, 4]])
    expect(matcher.feed("rs").map(&:to_a)).to eql([[4, 2, 6]])
  end

  it "keeps byte offsets absolute while streaming and after reset" do
    matcher = Algorithms::Search::AhoCorasickMatcher.new([[1, "abc"]])

    expect(matcher.feed("ab")).to be_empty
    expect(matcher.feed("cxyzabc").map(&:to_a)).to eql([[1, 0, 3], [1, 6, 9]])

    matcher.reset

    expect(matcher.feed("abc").map(&:to_a)).to eql([[1, 0, 3]])
  end

  it "yields the same matches returned from feeding a chunk" do
    matcher = Algorithms::Search::AhoCorasickMatcher.new([[1, "ab"]])
    yielded = []

    returned = matcher.feed("ab") { |match| yielded << match.to_a }

    expect(yielded).to eql([[1, 0, 2]])
    expect(returned.map(&:to_a)).to eql([[1, 0, 2]])
  end

  it "uses half-open byte intervals for multi-byte input" do
    matcher = Algorithms::Search::AhoCorasickMatcher.new([[1, "\xc3\xa9"]])

    expect(matcher.feed("\xc3\xa9").map(&:to_a)).to eql([[1, 0, 2]])
  end

  it "rejects empty patterns and non-string input" do
    expect { Algorithms::Search::AhoCorasickMatcher.new([[1, ""]]) }
      .to raise_error(ArgumentError)
    expect { Algorithms::Search::AhoCorasickMatcher.new([[1, nil]]) }
      .to raise_error(TypeError)

    matcher = Algorithms::Search::AhoCorasickMatcher.new([[1, "a"]])
    expect { matcher.feed(nil) }.to raise_error(TypeError)
  end
end
