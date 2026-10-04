=begin rdoc
    This module implements string algorithms. Documentation is provided for each algorithm.
    
=end

begin
  require 'CString'
rescue LoadError
end

module Algorithms
  module String
    C_STRING_AVAILABLE = respond_to?(:levenshtein_dist)

    class << self
      unless Algorithms::String::C_STRING_AVAILABLE
        # Pure-Ruby Levenshtein distance used only when the optional CString
        # extension could not be loaded; the C version is otherwise preferred.
        def levenshtein_dist(string1, string2)
          previous = (0..string2.length).to_a
          (1..string1.length).each do |i|
            current = [i]
            (1..string2.length).each do |j|
              cost = string1[i - 1] == string2[j - 1] ? 0 : 1
              current[j] = [current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost].min
            end
            previous = current
          end
          previous[string2.length]
        end
      end

      # Minimal cyclic representation (least rotation) of a string, working on
      # characters (Unicode code points). A multibyte character is never split:
      # the input is enumerated with String#each_char, and the returned starting
      # positions are character offsets. Returns the lexicographically smallest
      # rotation as a new String encoded like the input.
      #
      # Uses Booth's algorithm, which compares characters with <=> instead of
      # generating all rotations.
      #
      # Complexity: O(n) character comparisons, O(n) space, where n is the
      # number of characters.
      #
      #   Algorithms::String.minimal_rotation("baca")       #=> "abac" (start 3)
      #   Algorithms::String.minimal_rotation("éaéb")       #=> "aébé"
      #   Algorithms::String.minimal_rotation("")           #=> ""
      def minimal_rotation(string)
        assert_string!(string)
        return string.dup if string.empty?
        start = minimal_rotation_start(string.each_char.to_a)
        string[start..-1].concat(string[0...start])
      end

      # Byte-oriented variant of #minimal_rotation. The input is treated as a
      # sequence of bytes (String#bytes); the returned String and all offsets
      # are in byte units and are tagged with Encoding::BINARY. The result may
      # contain bytes taken from the middle of a multibyte character and is
      # therefore not claimed to be valid text in the original encoding.
      #
      # Complexity: O(n) byte comparisons, where n is the byte length.
      #
      #   Algorithms::String.minimal_rotation_bytes("baca") #=> "abac"
      def minimal_rotation_bytes(string)
        assert_string!(string)
        return String.new.force_encoding(::Encoding::BINARY) if string.empty?
        binary = string.dup.force_encoding(::Encoding::BINARY)
        start = minimal_rotation_start(string.bytes)
        binary[start..-1].concat(binary[0...start])
      end

      # Returns every character offset at which a lexicographically smallest
      # rotation begins. A non-primitive word (a repetition of a smaller word)
      # has several equivalent minima; a primitive word has exactly one.
      # Offsets are in characters, never in bytes.
      #
      # The minimum is found with Booth's algorithm and the remaining equal
      # starts are located with a Knuth-Morris-Pratt scan of the doubled word,
      # without enumerating or sorting all rotations.
      #
      # Complexity: O(n) character comparisons.
      #
      #   Algorithms::String.minimal_rotation_starts("baca")    #=> [3]
      #   Algorithms::String.minimal_rotation_starts("abab")    #=> [0, 2]
      #   Algorithms::String.minimal_rotation_starts("aaaa")    #=> [0, 1, 2, 3]
      #   Algorithms::String.minimal_rotation_starts("")        #=> []
      def minimal_rotation_starts(string)
        assert_string!(string)
        return [] if string.empty?
        minimal_rotation_starts_indices(string.each_char.to_a)
      end

      # Byte-oriented variant of #minimal_rotation_starts. Every returned offset
      # is a byte position and the comparison unit is a single byte.
      #
      # Complexity: O(n) byte comparisons.
      def minimal_rotation_starts_bytes(string)
        assert_string!(string)
        return [] if string.empty?
        minimal_rotation_starts_indices(string.bytes)
      end

      # Chen-Fox-Lyndon factorization of a string, working on characters
      # (Unicode code points). Returns an Array of non-increasing (relative to
      # lexicographic order) Lyndon words whose concatenation is the input.
      # A Lyndon word is strictly smaller than all of its nontrivial rotations.
      #
      # Uses Duval's algorithm; rotations are never enumerated.
      #
      # Complexity: O(n) character comparisons, O(n) space.
      #
      #   Algorithms::String.lyndon_factorization("ababa") #=> ["ab", "ab", "a"]
      #   Algorithms::String.lyndon_factorization("aaaa")  #=> ["a", "a", "a", "a"]
      #   Algorithms::String.lyndon_factorization("")      #=> []
      def lyndon_factorization(string)
        assert_string!(string)
        return [] if string.empty?
        lyndon_factorization_tokens(string.each_char.to_a).map { |factor| factor.join }
      end

      # Byte-oriented variant of #lyndon_factorization. Each factor is a
      # BINARY-encoded String of bytes and factors may start inside a multibyte
      # character; no claim is made that a factor is valid text.
      #
      # Complexity: O(n) byte comparisons.
      def lyndon_factorization_bytes(string)
        assert_string!(string)
        return [] if string.empty?
        lyndon_factorization_tokens(string.bytes).map { |factor| factor.pack('C*') }
      end

      private

      def assert_string!(string)
        unless string.is_a?(::String)
          raise ::TypeError, "expected a String, got #{string.class}"
        end
      end

      # Booth's least-rotation algorithm on an array of comparable tokens.
      # Only tokens#[i] and the <=> operator are used. Returns the starting
      # index of the lexicographically smallest rotation in O(n) comparisons.
      def minimal_rotation_start(tokens)
        n = tokens.length
        return 0 if n <= 1
        i = 0
        j = 1
        k = 0
        while i < n && j < n && k < n
          order = tokens[(i + k) % n] <=> tokens[(j + k) % n]
          if order.nil?
            raise ::ArgumentError, "rotation tokens are not comparable"
          elsif order == 0
            k += 1
          elsif order > 0
            i += k + 1
            i = j + 1 if i <= j
            k = 0
          else
            j += k + 1
            j = i + 1 if j <= i
            k = 0
          end
        end
        i < j ? i : j
      end

      # All rotation-start indices yielding the minimum rotation. The minimum
      # rotation is a prefix of the doubled word; KMP reports every occurrence
      # of that pattern in the first 2*n-1 positions, which is O(n).
      def minimal_rotation_starts_indices(tokens)
        n = tokens.length
        return [] if n == 0
        start = minimal_rotation_start(tokens)
        pattern = Array.new(n) { |offset| tokens[(start + offset) % n] }
        doubled = Array.new(2 * n - 1) { |offset| tokens[offset % n] }
        kmp_occurrences(doubled, pattern)
      end

      # Starting positions of every (possibly overlapping) occurrence of pattern
      # in text using the Knuth-Morris-Pratt algorithm.
      def kmp_occurrences(text, pattern)
        m = pattern.length
        return (0...text.length).to_a if m == 0
        failure = Array.new(m, 0)
        matched = 0
        (1...m).each do |index|
          while matched > 0 && pattern[index] != pattern[matched]
            matched = failure[matched - 1]
          end
          matched += 1 if pattern[index] == pattern[matched]
          failure[index] = matched
        end
        hits = []
        matched = 0
        text.each_with_index do |token, index|
          while matched > 0 && token != pattern[matched]
            matched = failure[matched - 1]
          end
          matched += 1 if token == pattern[matched]
          if matched == m
            hits << (index - m + 1)
            matched = failure[matched - 1]
          end
        end
        hits
      end

      # Duval's algorithm for the Chen-Fox-Lyndon factorization of a token
      # array. Returns an Array of token arrays, lexicographically non-increasing.
      def lyndon_factorization_tokens(tokens)
        factors = []
        n = tokens.length
        i = 0
        while i < n
          j = i + 1
          k = i
          while j < n && tokens[j] >= tokens[k]
            if tokens[j] > tokens[k]
              k = i
            else
              k += 1
            end
            j += 1
          end
          while i <= k
            length = j - k
            factors << Array.new(length) { |offset| tokens[i + offset] }
            i += length
          end
        end
        factors
      end
    end
  end
end
