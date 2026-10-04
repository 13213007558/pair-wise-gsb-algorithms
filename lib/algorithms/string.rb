=begin rdoc
    This module implements string algorithms. Documentation is provided for each algorithm.
    
=end

begin
  require 'CString'
rescue LoadError
end

module Algorithms
  module String
    unless respond_to?(:levenshtein_dist)
      # Pure-Ruby fallback used when the CString extension is not compiled.
      # Computes the Levenshtein (edit) distance between two strings, counted
      # in bytes (matching the C extension).
      #
      # Time Complexity: O(m * n), Space Complexity: O(n)
      def self.levenshtein_dist(str1, str2)
        s = str1.bytes
        t = str2.bytes
        m = s.length
        n = t.length
        return n if m == 0
        return m if n == 0

        prev = (0..n).to_a
        (1..m).each do |i|
          curr = [i]
          (1..n).each do |j|
            cost = s[i - 1] == t[j - 1] ? 0 : 1
            curr[j] = [curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost].min
          end
          prev = curr
        end
        prev[n]
      end
    end

    # --- Circular (necklace) string algorithms -----------------------------
    #
    # The following algorithms treat a string as a cycle: the last element
    # is followed by the first. All of them run in O(n) time (Booth's and
    # Duval's algorithms); they never materialize all n rotations.
    #
    # Each method takes a required +mode:+ keyword that states explicitly
    # which unit the string is processed in:
    #
    # [:bytes]
    #   The string is treated as a sequence of raw bytes. Multi-byte
    #   characters may be split by a rotation; consequently all returned
    #   strings are binary (ASCII-8BIT) and indices are byte offsets.
    # [:chars]
    #   The string is treated as a sequence of whole characters (as defined
    #   by String#each_char in the string's own encoding). Multi-byte UTF-8
    #   characters are never split; returned strings keep the input encoding
    #   and indices are character offsets.
    #
    # Returns the lexicographically smallest cyclic rotation of +str+
    # (the "minimal cyclic representation" of the necklace).
    #
    #   Algorithms::String.minimal_rotation("cbabc")              #=> "abccb"
    #   Algorithms::String.minimal_rotation("€b€a", mode: :chars) #=> "a€b€"
    #
    # Time Complexity: O(n)
    def self.minimal_rotation(str, mode: :bytes)
      seq = circular_sequence(str, mode)
      return build_circular_result([], str, mode) if seq.empty?

      index = min_rotation_index(seq)
      rotated = seq[index..-1] + seq[0...index]
      build_circular_result(rotated, str, mode)
    end

    # Returns the sorted list of all start offsets whose rotation equals the
    # minimal cyclic representation of +str+. Offsets are byte offsets in
    # :bytes mode and character offsets in :chars mode. A non-primitive word
    # (e.g. "ababab") has one such offset per repetition of its primitive
    # root. Returns [] for an empty string.
    #
    #   Algorithms::String.minimal_rotation_starts("ababab") #=> [0, 2, 4]
    #
    # Time Complexity: O(n)
    def self.minimal_rotation_starts(str, mode: :bytes)
      min_rotation_indices(circular_sequence(str, mode))
    end

    # Returns the Chen-Fox-Lyndon factorization of +str+: the unique
    # factorization into a non-increasing sequence of Lyndon words. The
    # factors concatenate back to +str+ (in the chosen mode's units).
    #
    #   Algorithms::String.lyndon_factorization("cbabc") #=> ["c", "b", "abc"]
    #
    # Time Complexity: O(n)
    def self.lyndon_factorization(str, mode: :bytes)
      seq = circular_sequence(str, mode)
      lyndon_factorize(seq).map { |start, len| build_circular_result(seq[start, len], str, mode) }
    end

    # --- Sequence-level cores ----------------------------------------------
    #
    # These methods operate on any sequence that responds to #length and
    # #[] with elements comparable via < and == (e.g. an Array of Integers
    # or single-character Strings). They are the linear-time cores behind
    # the string-level API above.

    # Booth's algorithm: index of the lexicographically least rotation of
    # +seq+. Returns 0 for an empty or single-element sequence.
    #
    # Time Complexity: O(n)
    def self.min_rotation_index(seq)
      n = seq.length
      return 0 if n < 2

      i = 0
      j = 1
      k = 0
      while i < n && j < n && k < n
        a = seq[(i + k) % n]
        b = seq[(j + k) % n]
        if a == b
          k += 1
        elsif a > b
          i = i + k + 1
          i += 1 if i == j
          k = 0
        else
          j = j + k + 1
          j += 1 if j == i
          k = 0
        end
      end
      i < j ? i : j
    end

    # All start indices whose rotation of +seq+ equals the least rotation,
    # in ascending order. Returns [] for an empty sequence.
    #
    # Time Complexity: O(n)
    def self.min_rotation_indices(seq)
      n = seq.length
      return [] if n == 0

      first = min_rotation_index(seq)
      period = minimal_period(seq)
      starts = (0...(n / period)).map { |t| (first + t * period) % n }
      starts.sort!
      starts
    end

    # Length of the shortest block whose repetition tiles +seq+ (n if +seq+
    # is primitive), computed with the KMP prefix function. Returns 0 for an
    # empty sequence.
    #
    # Time Complexity: O(n)
    def self.minimal_period(seq)
      n = seq.length
      return 0 if n == 0

      pi = Array.new(n, 0)
      (1...n).each do |i|
        j = pi[i - 1]
        j = pi[j - 1] while j > 0 && seq[i] != seq[j]
        j += 1 if seq[i] == seq[j]
        pi[i] = j
      end
      period = n - pi[n - 1]
      n % period == 0 ? period : n
    end

    # Duval's algorithm: Chen-Fox-Lyndon factorization of +seq+, returned as
    # a list of [start, length] pairs covering the whole sequence.
    #
    # Time Complexity: O(n)
    def self.lyndon_factorize(seq)
      n = seq.length
      factors = []
      i = 0
      while i < n
        j = i + 1
        k = i
        while j < n && seq[k] <= seq[j]
          k = seq[k] < seq[j] ? i : k + 1
          j += 1
        end
        while i <= k
          factors << [i, j - k]
          i += j - k
        end
      end
      factors
    end

    # Validates the input and converts it to the element sequence the
    # sequence-level cores work on. Raises TypeError for non-strings and
    # ArgumentError for an unknown mode, so byte/character handling can
    # never be ambiguous.
    def self.circular_sequence(str, mode)
      unless str.is_a?(::String)
        raise TypeError, "expected a String, got #{str.class}"
      end

      case mode
      when :bytes then str.bytes
      when :chars then str.each_char.to_a
      else
        raise ArgumentError, "unknown mode #{mode.inspect}; expected :bytes or :chars"
      end
    end
    private_class_method :circular_sequence

    # Builds the result string for the given mode. Byte mode always returns
    # a binary (ASCII-8BIT) string, since a byte-level rotation may split a
    # multi-byte character; char mode preserves the input encoding.
    def self.build_circular_result(elements, source, mode)
      if mode == :bytes
        elements.pack('C*')
      else
        result = elements.join
        result.force_encoding(source.encoding)
        result
      end
    end
    private_class_method :build_circular_result
  end
end
