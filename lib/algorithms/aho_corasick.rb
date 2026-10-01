=begin rdoc
    Aho-Corasick multi-pattern string matching. The automaton is compiled once from a
    set of patterns and can then be reused to scan any number of streams, either in a
    single pass or chunk by chunk.

=end
module Algorithms::Search
  # Aho-Corasick Algorithm multi-pattern search: Efficiently finds all occurrences of
  # many fixed byte strings in a single pass over the input. The pattern set is compiled
  # once into an automaton that can be shared by any number of independent scan sessions,
  # so streams can be scanned chunk by chunk without recompiling and without losing
  # matches that span chunk boundaries.
  #
  # All overlapping matches are reported, including patterns that are suffixes of other
  # patterns. Duplicate patterns are kept and reported under their own pattern id (the
  # index of the pattern in the list given to the constructor). Empty patterns are
  # rejected with ArgumentError.
  #
  # Offsets are byte offsets into the scanned stream. A match reports +start_offset+
  # (inclusive) and +end_offset+ (exclusive).
  #
  # Complexity: O(m) to compile and O(n + z) to scan, where m is the total pattern
  # length, n is the input length, and z is the number of matches.
  #
  #   matcher = Algorithms::Search::AhoCorasick.new(["he", "she", "hers", "his"])
  #   matcher.scan("ushers") #=> [#<Match pattern_id=1, 1...4>, #<Match pattern_id=0, 2...4>, #<Match pattern_id=2, 2...6>]
  #
  #   session = matcher.new_session
  #   session.feed("us")  #=> []
  #   session.feed("hers") #=> same matches as scanning "ushers" at once
  class AhoCorasick
    # A single match. +pattern_id+ is the index of the pattern in the list passed to
    # the constructor, +pattern+ is the matched pattern itself, and
    # +start_offset+/+end_offset+ are byte offsets into the stream (end exclusive).
    Match = Struct.new(:pattern_id, :pattern, :start_offset, :end_offset)

    # Internal automaton node. Nodes are shared by all sessions and never mutated
    # after the automaton has been built.
    class Node
      attr_accessor :failure
      attr_reader :transitions, :outputs

      def initialize
        @transitions = {}
        @outputs = []
        @failure = nil
      end
    end

    # The frozen list of patterns this matcher was compiled from.
    attr_reader :patterns

    # Compiles the given patterns into an automaton. Raises ArgumentError if the list
    # is empty or any pattern is nil, empty, or not a String.
    def initialize(patterns)
      raise ArgumentError, "at least one pattern is required" if patterns.nil? || patterns.empty?
      @patterns = patterns.each_with_index.map do |pattern, index|
        unless pattern.is_a?(String) && !pattern.empty?
          raise ArgumentError, "pattern #{index} must be a non-empty String"
        end
        pattern.dup.freeze
      end.freeze
      @lengths = @patterns.map(&:bytesize).freeze
      build_automaton
    end

    # Returns a new independent scan session. Sessions keep their own state, so any
    # number of them can be interleaved on the same matcher.
    def new_session
      Session.new(@root, @patterns, @lengths)
    end

    # Scans the whole string in one pass and returns an array of Matches in the order
    # they occur. Equivalent to feeding the string to a fresh session.
    def scan(string)
      session = new_session
      session.feed(string).concat(session.finish)
    end

    private

    def build_automaton
      @root = Node.new
      @patterns.each_with_index do |pattern, id|
        node = @root
        pattern.each_byte do |byte|
          node = (node.transitions[byte] ||= Node.new)
        end
        node.outputs << id
      end

      @root.failure = @root
      queue = []
      @root.transitions.each_value do |child|
        child.failure = @root
        queue << child
      end
      until queue.empty?
        node = queue.shift
        node.transitions.each do |byte, child|
          failure = node.failure
          failure = failure.failure while failure != @root && !failure.transitions.key?(byte)
          child.failure = failure.transitions[byte] || @root
          # Inherit the failure node's outputs so suffix patterns are reported too.
          child.outputs.concat(child.failure.outputs)
          queue << child
        end
      end
    end

    # State of one scan. A session belongs to a single stream: feed it chunks in order
    # and it returns the matches completed by each chunk. Matches that span chunk
    # boundaries are reported once the chunk containing their final byte arrives.
    class Session
      def initialize(root, patterns, lengths)
        @root = root
        @patterns = patterns
        @lengths = lengths
        reset
      end

      # Feeds one chunk of the stream and returns the matches it completes.
      def feed(chunk)
        raise ArgumentError, "chunk must be a String" unless chunk.is_a?(String)
        matches = []
        chunk.each_byte do |byte|
          node = @node
          node = node.failure while node != @root && !node.transitions.key?(byte)
          @node = node.transitions[byte] || @root
          @offset += 1
          @node.outputs.each do |id|
            matches << Match.new(id, @patterns[id], @offset - @lengths[id], @offset)
          end
        end
        matches
      end

      # Ends the scan. No buffered input remains in an Aho-Corasick scan, so this
      # always returns an empty array; the session is reset and can be reused.
      def finish
        reset
        []
      end

      # Resets the session to the beginning of a new stream.
      def reset
        @node = @root
        @offset = 0
        self
      end
    end
  end
end
