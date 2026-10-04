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

  describe Algorithms::Search::AhoCorasickMatcher do
    def match_array(matches)
      matches.map { |match| [match.pattern_id, match.start_byte, match.end_byte] }
    end

    it "finds overlapping matches across chunks with shared prefixes and suffixes" do
      matcher = described_class.new([
        [10, "he"],
        [30, "his"],
        [20, "she"],
        [40, "hers"]
      ])

      expect(match_array(matcher.feed("us"))).to eql([])
      expect(match_array(matcher.feed("he"))).to eql([
        [10, 2, 4],
        [20, 1, 4]
      ])
      expect(match_array(matcher.feed("rs"))).to eql([
        [40, 2, 6]
      ])
    end

    it "preserves absolute byte intervals for matches split by chunk boundaries" do
      matcher = described_class.new([[5, "cde"]])

      expect(match_array(matcher.feed("abc"))).to eql([])
      expect(match_array(matcher.feed("defgh"))).to eql([
        [5, 2, 5]
      ])
    end

    it "returns duplicate patterns with different IDs in a deterministic order" do
      matcher = described_class.new([
        [7, "ab"],
        [3, "ab"]
      ])

      expect(match_array(matcher.feed("xab"))).to eql([
        [3, 1, 3],
        [7, 1, 3]
      ])
    end

    it "uses registration order when pattern IDs and end positions tie" do
      matcher = described_class.new([
        [3, "ab"],
        [3, "ab"]
      ])

      expect(match_array(matcher.feed("ab"))).to eql([
        [3, 0, 2],
        [3, 0, 2]
      ])
    end

    it "returns all overlapping matches without rerunning each pattern" do
      matcher = described_class.new({
        0 => "ab",
        1 => "aba",
        2 => "bab"
      })

      expect(match_array(matcher.feed("ab"))).to eql([
        [0, 0, 2]
      ])
      expect(match_array(matcher.feed("ab"))).to eql([
        [1, 0, 3],
        [0, 2, 4],
        [2, 1, 4]
      ])
    end

    it "uses array indices as pattern IDs when patterns are supplied as strings" do
      matcher = described_class.new(["ab", "ba"])

      expect(match_array(matcher.feed("aba"))).to eql([
        [0, 0, 2],
        [1, 1, 3]
      ])
    end

    it "counts byte positions for multibyte strings" do
      matcher = described_class.new([[1, "\u00e9"]])
      first_byte = "\u00e9".bytes.first.chr
      second_byte = "\u00e9".bytes.last.chr

      expect(match_array(matcher.feed(first_byte))).to eql([])
      expect(match_array(matcher.feed(second_byte))).to eql([
        [1, 0, 2]
      ])
    end

    it "can reset and reuse the built automaton" do
      matcher = described_class.new([[1, "ab"]])
      expect(match_array(matcher.feed("xab"))).to eql([[1, 1, 3]])

      matcher.reset

      expect(match_array(matcher.feed("ab"))).to eql([[1, 0, 2]])
    end

    it "rejects empty patterns" do
      expect { described_class.new([[1, ""]]) }.to raise_error(
        ArgumentError, "empty patterns are not supported"
      )
      expect { described_class.new([""]) }.to raise_error(
        ArgumentError, "empty patterns are not supported"
      )
    end

    it "supports building with no patterns" do
      matcher = described_class.new([])

      expect(match_array(matcher.feed("anything"))).to eql([])
    end
  end
end
