$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

# Counts single-token index reads performed by the core rotation algorithms.
class CountingArray
  attr_reader :accesses

  def initialize(items)
    @items = items
    @accesses = 0
  end

  def length
    @items.length
  end

  def [](index)
    @accesses += 1
    @items[index % @items.length]
  end
end

def brute_force_min_rotation(word)
  return "" if word.empty?
  rotations = (0...word.length).map { |start| word[start..-1] + word[0...start] }
  rotations.min
end

def brute_force_min_rotation_starts(word)
  minimum = brute_force_min_rotation(word)
  (0...word.length).select { |start| (word[start..-1] + word[0...start]) == minimum }
end

def brute_force_lyndon_factorization(word)
  factors = []
  rest = word
  until rest.empty?
    length = 1
    (1..rest.length).each do |candidate_length|
      candidate = rest[0...candidate_length]
      rotations = (1...candidate_length).map do |offset|
        candidate[offset..-1] + candidate[0...offset]
      end
      length = candidate_length if rotations.all? { |rotation| candidate < rotation }
    end
    factors << rest[0...length]
    rest = rest[length..-1]
  end
  factors
end

if defined? Algorithms::String
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
    let(:mod) { Algorithms::String }

    describe "minimal rotation" do
      it "handles empty strings, uniform strings and a basic rotation" do
        expect(mod.minimal_rotation("")).to eql("")
        expect(mod.minimal_rotation("a")).to eql("a")
        expect(mod.minimal_rotation("baca")).to eql("abac")
        expect(mod.minimal_rotation("aaaa")).to eql("aaaa")
      end

      it "does not mutate the input and preserves its encoding" do
        input = "baca".freeze
        expect(mod.minimal_rotation(input)).to eql("abac")
        expect(input).to eql("baca")
        expect(mod.minimal_rotation("".dup.force_encoding(Encoding::UTF_8)).encoding).to eql(Encoding::UTF_8)
      end

      it "works with frozen multibyte inputs in all three interfaces" do
        input = "éaéb中".dup.force_encoding(Encoding::UTF_8).freeze
        expect { mod.minimal_rotation(input) }.not_to raise_error
        expect { mod.minimal_rotation_bytes(input) }.not_to raise_error
        expect { mod.minimal_rotation_starts(input) }.not_to raise_error
        expect { mod.lyndon_factorization(input) }.not_to raise_error
        expect { mod.lyndon_factorization_bytes(input) }.not_to raise_error
      end

      (1..7).each do |length|
        it "matches brute force on every binary word of length #{length}" do
          (0...(2 ** length)).each do |mask|
            word = (0...length).map { |bit| mask[bit] == 1 ? "b" : "a" }.join
            expect(mod.minimal_rotation(word)).to eql(brute_force_min_rotation(word))
          end
        end
      end

      it "matches brute force on every ternary word of length at most 4" do
        alphabet = ["a", "b", "c"]
        words = [""]
        4.times do
          words = words.flat_map { |word| alphabet.map { |letter| word + letter } }
          words.each do |word|
            expect(mod.minimal_rotation(word)).to eql(brute_force_min_rotation(word))
          end
        end
      end

      it "works on a primitive long-period word without sorting rotations" do
        word = "a" * 500 + "ba"
        expect(mod.minimal_rotation(word)).to eql("a" * 501 + "b")
        expect(mod.minimal_rotation_starts(word)).to eql([501])
      end
    end

    describe "minimal rotation starts" do
      it "handles the empty string and primitive words" do
        expect(mod.minimal_rotation_starts("")).to eql([])
        expect(mod.minimal_rotation_starts("baca")).to eql([3])
        expect(mod.minimal_rotation_starts("cba")).to eql([2])
      end

      it "returns every equivalent start for non-primitive words" do
        expect(mod.minimal_rotation_starts("aaaa")).to eql([0, 1, 2, 3])
        expect(mod.minimal_rotation_starts("abab")).to eql([0, 2])
        expect(mod.minimal_rotation_starts("abcabcabc")).to eql([0, 3, 6])
      end

      (1..7).each do |length|
        it "matches brute force on every binary word of length #{length}" do
          (0...(2 ** length)).each do |mask|
            word = (0...length).map { |bit| mask[bit] == 1 ? "b" : "a" }.join
            expect(mod.minimal_rotation_starts(word)).to eql(brute_force_min_rotation_starts(word))
          end
        end
      end

      it "agrees with brute force and with the minimal period on ternary words" do
        alphabet = ["a", "b", "c"]
        words = [""]
        4.times do
          words = words.flat_map { |word| alphabet.map { |letter| word + letter } }
        end
        words.each do |word|
          starts = mod.minimal_rotation_starts(word)
          expect(starts).to eql(brute_force_min_rotation_starts(word))
          next if word.empty?
          period = (1..word.length).find do |p|
            word.length % p == 0 && word == word[0...p] * (word.length / p)
          end
          expect(starts.length).to eql(word.length / period)
        end
      end
    end

    describe "Lyndon factorization" do
      it "handles empty strings and uniform strings" do
        expect(mod.lyndon_factorization("")).to eql([])
        expect(mod.lyndon_factorization("a")).to eql(["a"])
        expect(mod.lyndon_factorization("aaaa")).to eql(["a", "a", "a", "a"])
      end

      it "produces the known factorizations of classic examples" do
        expect(mod.lyndon_factorization("ababa")).to eql(["ab", "ab", "a"])
        expect(mod.lyndon_factorization("ababbaba")).to eql(["ababb", "ab", "a"])
        expect(mod.lyndon_factorization("baba")).to eql(["b", "ab", "a"])
      end

      it "returns Lyndon words in non-increasing order that reconstruct the input" do
        word = "abcabxabcab"
        factors = mod.lyndon_factorization(word)
        expect(factors.join).to eql(word)
        factors.each do |factor|
          (1...factor.length).each do |offset|
            expect(factor < factor[offset..-1] + factor[0...offset]).to eql(true)
          end
        end
        expect(factors.each_cons(2).all? { |left, right| left >= right }).to eql(true)
      end

      (1..6).each do |length|
        it "matches brute force on every binary word of length #{length}" do
          (0...(2 ** length)).each do |mask|
            word = (0...length).map { |bit| mask[bit] == 1 ? "b" : "a" }.join
            expect(mod.lyndon_factorization(word)).to eql(brute_force_lyndon_factorization(word))
          end
        end
      end
    end

    describe "character versus byte semantics" do
      it "indexes characters with each_char for multibyte UTF-8 input" do
        word = "éaéb".dup.force_encoding(Encoding::UTF_8)
        expect(word.length).to eql(4)
        expect(word.bytesize).to eql(6)
        expect(mod.minimal_rotation(word)).to eql("aébé")
        expect(mod.minimal_rotation(word).valid_encoding?).to eql(true)
        expect(mod.minimal_rotation_starts(word)).to eql([1])
        expect(mod.lyndon_factorization(word).join).to eql(word)
        expect(mod.lyndon_factorization(word).all?(&:valid_encoding?)).to eql(true)
      end

      it "indexes bytes in the byte variants and never pretends splits are characters" do
        word = "éé".dup.force_encoding(Encoding::UTF_8)
        bytes = word.bytes
        expect(bytes).to eql([0xC3, 0xA9, 0xC3, 0xA9])
        # The byte minimum starts at a continuation byte (index 1), cutting the
        # first é in half; the result is raw BINARY data, not text. The
        # character view sees two identical characters and keeps starts 0, 1.
        expect(mod.minimal_rotation_bytes(word).bytes).to eql([0xA9, 0xC3, 0xA9, 0xC3])
        expect(mod.minimal_rotation_bytes(word).encoding).to eql(Encoding::BINARY)
        expect(mod.minimal_rotation_starts_bytes(word)).to eql([1, 3])
        expect(mod.minimal_rotation_starts(word)).to eql([0, 1])
        expect(mod.minimal_rotation(word)).to eql("éé")
        factors = mod.lyndon_factorization_bytes(word)
        expect(factors.map(&:bytes)).to eql([[0xC3], [0xA9, 0xC3], [0xA9]])
        expect(factors.all? { |factor| factor.encoding == Encoding::BINARY }).to eql(true)
      end

      it "agrees with brute force on byte-exhaustive short words" do
        [2, 3, 4, 5].each do |length|
          (0...(2 ** length)).each do |mask|
            bytes = (0...length).map { |bit| mask[bit] == 1 ? 0x62 : 0x61 }
            word = bytes.pack('C*')
            expect(mod.minimal_rotation_bytes(word)).to eql(brute_force_min_rotation(word))
            expect(mod.minimal_rotation_starts_bytes(word)).to eql(brute_force_min_rotation_starts(word))
            expect(mod.lyndon_factorization_bytes(word)).to eql(brute_force_lyndon_factorization(word))
          end
        end
      end
    end

    describe "linear token access" do
      [128, 512, 2048, 8192].each do |length|
        it "uses a linear number of token accesses on a primitive word of length #{length}" do
          tokens = Array.new(length - 2, 0) + [1, 2]
          rotation = CountingArray.new(tokens)
          mod.send(:minimal_rotation_start, rotation)
          expect(rotation.accesses).to be <= 8 * length

          starts = CountingArray.new(tokens)
          mod.send(:minimal_rotation_starts_indices, starts)
          expect(starts.accesses).to be <= 12 * length

          factors = CountingArray.new(tokens)
          mod.send(:lyndon_factorization_tokens, factors)
          expect(factors.accesses).to be <= 8 * length
        end
      end

      it "stays linear as the long-period word grows instead of quadratic" do
        ratios = [256, 1024, 4096].map do |length|
          tokens = Array.new(length - 2, 0) + [1, 2]
          rotation = CountingArray.new(tokens)
          mod.send(:minimal_rotation_start, rotation)
          rotation.accesses.to_f / length
        end
        expect(ratios.max - ratios.min).to be < 2.0
        expect(ratios.max).to be < 8.0
      end
    end

    describe "argument handling" do
      it "raises TypeError on non-String arguments" do
        expect { mod.minimal_rotation(:abc) }.to raise_error(TypeError)
        expect { mod.minimal_rotation_starts(nil) }.to raise_error(TypeError)
        expect { mod.lyndon_factorization_bytes(123) }.to raise_error(TypeError)
        expect { mod.minimal_rotation_bytes([97]) }.to raise_error(TypeError)
      end
    end
  end
end
