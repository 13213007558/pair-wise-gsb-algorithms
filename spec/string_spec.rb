$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe "string algorithms" do
  it "should do levenshtein distance" do
    expect(Algorithms::String.levenshtein_dist("Hello", "Hel")).to eql(2)
    expect(Algorithms::String.levenshtein_dist("Hello", "")).to eql(5)
    expect(Algorithms::String.levenshtein_dist("", "Hello")).to eql(5)
    expect(Algorithms::String.levenshtein_dist("Hello", "Hello")).to eql(0)
    expect(Algorithms::String.levenshtein_dist("Hello", "ello")).to eql(1)
    expect(Algorithms::String.levenshtein_dist("Hello", "Mello")).to eql(1)
  end
end

describe "circular string algorithms" do
  let(:string) { Algorithms::String }

  def rotations(s)
    (0...s.length).map { |i| s[i..-1] + s[0...i] }
  end

  def brute_min_rotation(s)
    rotations(s).min || ""
  end

  def brute_min_rotation_starts(s)
    min = brute_min_rotation(s)
    (0...s.length).select { |i| s[i..-1] + s[0...i] == min }
  end

  def lyndon_word?(w)
    !w.empty? && (1...w.length).all? { |i| w < w[i..-1] + w[0...i] }
  end

  describe "known answers" do
    it "computes the minimal cyclic representation" do
      expect(string.minimal_rotation("cbabc")).to eql("abccb")
      expect(string.minimal_rotation("bba")).to eql("abb")
      expect(string.minimal_rotation("aba")).to eql("aab")
    end

    it "computes all equivalent minimal starts" do
      expect(string.minimal_rotation_starts("cbabc")).to eql([2])
      expect(string.minimal_rotation_starts("bba")).to eql([2])
    end

    it "computes the Lyndon factorization" do
      expect(string.lyndon_factorization("cbabc")).to eql(["c", "b", "abc"])
      expect(string.lyndon_factorization("aabb")).to eql(["aabb"])
      expect(string.lyndon_factorization("abcdab")).to eql(["abcd", "ab"])
    end
  end

  describe "edge cases" do
    it "handles the empty string" do
      expect(string.minimal_rotation("")).to eql("")
      expect(string.minimal_rotation_starts("")).to eql([])
      expect(string.lyndon_factorization("")).to eql([])
    end

    it "handles a single character" do
      expect(string.minimal_rotation("z")).to eql("z")
      expect(string.minimal_rotation_starts("z")).to eql([0])
      expect(string.lyndon_factorization("z")).to eql(["z"])
    end

    it "handles strings of one repeated character" do
      expect(string.minimal_rotation("aaaa")).to eql("aaaa")
      expect(string.minimal_rotation_starts("aaaa")).to eql([0, 1, 2, 3])
      expect(string.lyndon_factorization("aaaa")).to eql(["a", "a", "a", "a"])
    end

    it "handles non-primitive words" do
      expect(string.minimal_rotation("ababab")).to eql("ababab")
      expect(string.minimal_rotation_starts("ababab")).to eql([0, 2, 4])
      expect(string.minimal_rotation_starts("xyzxyz")).to eql([0, 3])
      expect(string.lyndon_factorization("ababab")).to eql(["ab", "ab", "ab"])
      expect(string.lyndon_factorization("xyzxyz")).to eql(["xyz", "xyz"])
    end
  end

  describe "byte vs character modes" do
    it "requires an explicit, valid mode" do
      expect { string.minimal_rotation("abc", mode: :graphemes) }.to raise_error(ArgumentError)
      expect { string.minimal_rotation_starts("abc", mode: nil) }.to raise_error(ArgumentError)
      expect { string.lyndon_factorization("abc", mode: "chars") }.to raise_error(ArgumentError)
      expect { string.minimal_rotation(123) }.to raise_error(TypeError)
    end

    it "never splits multi-byte characters in :chars mode" do
      s = "€b€a" # € is three bytes in UTF-8
      expect(string.minimal_rotation(s, mode: :chars)).to eql("a€b€")
      expect(string.minimal_rotation_starts(s, mode: :chars)).to eql([3]) # character offset
      factors = string.lyndon_factorization("日本語ab", mode: :chars)
      expect(factors.join).to eql("日本語ab")
      expect(factors).to all(be_valid_encoding)
    end

    it "works on raw bytes in :bytes mode and says so by returning binary" do
      # "€" is 0xE2 0x82 0xAC; the least byte rotation starts mid-character.
      rot = string.minimal_rotation("€", mode: :bytes)
      expect(rot.encoding).to eql(Encoding::BINARY)
      expect(rot.bytes).to eql([0x82, 0xAC, 0xE2])
      expect(rot.dup.force_encoding("UTF-8").valid_encoding?).to be false
      # ...while :chars mode keeps the character intact.
      expect(string.minimal_rotation("€", mode: :chars)).to eql("€")
    end

    it "reports byte offsets in :bytes mode" do
      # 'a' starts at byte offset 3 + 1 + 3 = 7 in "€b€a".
      expect(string.minimal_rotation_starts("€b€a", mode: :bytes)).to eql([7])
    end
  end

  describe "exhaustive verification against brute force" do
    it "matches rotation enumeration on every binary string up to length 9" do
      (0..9).each do |len|
        ["a", "b"].repeated_permutation(len) do |chars|
          s = chars.join
          expect(string.minimal_rotation(s)).to eql(brute_min_rotation(s))
          expect(string.minimal_rotation_starts(s)).to eql(brute_min_rotation_starts(s))
        end
      end
    end

    it "matches rotation enumeration on every ternary string up to length 6" do
      (0..6).each do |len|
        ["a", "b", "c"].repeated_permutation(len) do |chars|
          s = chars.join
          expect(string.minimal_rotation(s)).to eql(brute_min_rotation(s))
          expect(string.minimal_rotation_starts(s)).to eql(brute_min_rotation_starts(s))
        end
      end
    end

    it "produces valid Lyndon factorizations on every binary string up to length 9" do
      (0..9).each do |len|
        ["a", "b"].repeated_permutation(len) do |chars|
          s = chars.join
          factors = string.lyndon_factorization(s)
          expect(factors.join).to eql(s)
          factors.each { |f| expect(lyndon_word?(f)).to be(true), "expected #{f.inspect} of #{s.inspect} to be a Lyndon word" }
          expect(factors.each_cons(2).all? { |x, y| x >= y }).to be(true), "expected non-increasing factors for #{s.inspect}"
        end
      end
    end
  end

  describe "linear-time behavior on long periodic strings" do
    # Counts element accesses so the specs can assert linear growth without
    # timing walls.
    class CountingSequence
      attr_reader :reads

      def initialize(elements)
        @elements = elements
        @reads = 0
      end

      def length
        @elements.length
      end

      def [](index)
        @reads += 1
        @elements[index]
      end
    end

    def count_reads(algorithm, s)
      seq = CountingSequence.new(s.chars)
      algorithm.call(seq)
      seq.reads
    end

    algorithms = {
      "min_rotation_index" => ->(seq) { Algorithms::String.min_rotation_index(seq) },
      "min_rotation_indices" => ->(seq) { Algorithms::String.min_rotation_indices(seq) },
      "lyndon_factorize" => ->(seq) { Algorithms::String.lyndon_factorize(seq) }
    }

    algorithms.each do |name, algorithm|
      it "#{name} performs O(n) element accesses on periodic strings" do
        sizes = [2_000, 4_000, 8_000, 16_000, 32_000]
        reads_per_element = sizes.map do |n|
          count_reads(algorithm, "ab" * (n / 2)).to_f / n
        end
        # A quadratic "generate all rotations and sort" approach would need
        # Theta(n^2) reads, so reads/element would grow with n; a linear
        # algorithm keeps it bounded.
        expect(reads_per_element.last).to be <= 12.0
        expect(reads_per_element.last).to be <= reads_per_element.first * 1.5
      end
    end

    it "handles long highly periodic strings correctly" do
      s = "abc" * 10_000
      expect(string.minimal_rotation(s)).to eql(s)
      expect(string.minimal_rotation_starts(s)).to eql((0...10_000).map { |t| t * 3 })
      expect(string.lyndon_factorization(s)).to eql(["abc"] * 10_000)

      shifted = "b" + "ab" * 5_000
      expect(string.minimal_rotation(shifted)).to eql("ab" * 5_000 + "b")
      expect(string.minimal_rotation_starts(shifted)).to eql([1])
    end
  end
end
