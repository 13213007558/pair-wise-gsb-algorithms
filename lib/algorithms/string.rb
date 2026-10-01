=begin rdoc
    This module implements string algorithms. Documentation is provided for each algorithm.
    
=end

begin
  require 'CString'
rescue LoadError
end

module Algorithms
  module String
    # A compiled Aho-Corasick automaton for matching many byte strings in one pass.
    #
    # Patterns may be supplied as strings, [pattern, id] pairs, or hashes with
    # :pattern and :id/:pattern_id keys. A pattern table can be shared by any
    # number of independent scanning sessions.
    # End offsets are byte positions immediately after the matched bytes.
    class MultiPatternMatcher
      Match = Struct.new(:pattern_id, :pattern, :pattern_index,
                         :start_offset, :end_offset) do
        alias_method :id, :pattern_id
        alias_method :start, :start_offset
        alias_method :stop, :end_offset

        def deconstruct
          [pattern_id, start_offset, end_offset]
        end

        def deconstruct_keys(keys)
          to_h.slice(*keys)
        end
      end

      Entry = Struct.new(:pattern_id, :pattern, :pattern_index, :length)

      # Maintains independent state while feeding chunks of a byte stream.
      class Scanner
        attr_reader :offset

        def initialize(matcher)
          @matcher = matcher
          @state = 0
          @offset = 0
          @matches = []
        end

        def scan(chunk)
          raise ArgumentError, "chunk must be a String" unless chunk.is_a?(::String)

          found = []
          chunk.each_byte do |byte|
            @state = @matcher.next_state(@state, byte)
            @matcher.each_output(@state) do |entry|
              end_offset = @offset + 1
              match = Match.new(
                entry.pattern_id,
                entry.pattern,
                entry.pattern_index,
                end_offset - entry.length,
                end_offset
              )
              found << match
              @matches << match
            end
            @offset += 1
          end
          found
        end

        def feed(chunk)
          scan(chunk)
        end

        def <<(chunk)
          scan(chunk)
          self
        end

        # All matches are emitted on their final byte, so there is no deferred
        # work when a stream ends.
        def finish
          @matches.dup
        end

        def matches
          @matches.dup
        end
      end

      def self.compile(patterns)
        new(patterns)
      end

      def initialize(patterns)
        patterns = Array(patterns)
        @children = [{}]
        @failure = [0]
        @terminal = [[]]
        @dictionary_suffix = [nil]
        @patterns = []

        patterns.each_with_index do |pattern, index|
          add_pattern(pattern, index)
        end

        build_failure_links
      end

      def scan(input)
        raise ArgumentError, "input must be a String" unless input.is_a?(::String)

        scanner = new_scanner
        scanner.scan(input)
        scanner.finish
      end

      def new_scanner
        Scanner.new(self)
      end

      def scanner
        new_scanner
      end

      def next_state(state, byte)
        while state != 0 && !@children[state].key?(byte)
          state = @failure[state]
        end
        @children[state].fetch(byte, 0)
      end

      def each_output(state, &block)
        state = @dictionary_suffix[state] if @terminal[state].empty?

        while state
          @terminal[state].each(&block)
          state = @dictionary_suffix[state]
        end
      end

      private

      def add_pattern(specification, index)
        pattern, pattern_id = normalize_pattern(specification)
        bytes = pattern.each_byte.to_a
        raise ArgumentError, "patterns cannot be empty" if bytes.empty?

        state = 0
        bytes.each do |byte|
          state = @children[state][byte] ||= begin
            new_state = @children.length
            @children << {}
            @failure << 0
            @terminal << []
            @dictionary_suffix << nil
            new_state
          end
        end

        entry = Entry.new(pattern_id, pattern, index, bytes.length)
        @terminal[state] << entry
        @patterns << entry
      end

      def normalize_pattern(specification)
        case specification
        when ::String
          pattern = specification
          [pattern.b, pattern]
        when Array
          unless specification.length == 2
            raise ArgumentError, "pattern pairs must contain a pattern and an id"
          end
          pattern, pattern_id = specification
          verify_pattern(pattern)
          [pattern.b, pattern_id.nil? ? pattern : pattern_id]
        when Hash
          pattern = specification.fetch(:pattern) do
            raise ArgumentError, "pattern specification must include :pattern"
          end
          verify_pattern(pattern)
          pattern_id = specification.fetch(:pattern_id, specification.fetch(:id, pattern))
          [pattern.b, pattern_id]
        else
          raise ArgumentError, "unsupported pattern specification: #{specification.inspect}"
        end
      end

      def verify_pattern(pattern)
        unless pattern.is_a?(::String)
          raise ArgumentError, "pattern must be a String"
        end
        raise ArgumentError, "patterns cannot be empty" if pattern.bytesize.zero?
      end

      def build_failure_links
        queue = []

        @children[0].each_value do |child|
          @failure[child] = 0
          @dictionary_suffix[child] = nil
          queue << child
        end

        head = 0
        while head < queue.length
          state = queue[head]
          head += 1

          @children[state].each do |byte, child|
            fallback = @failure[state]
            while fallback != 0 && !@children[fallback].key?(byte)
              fallback = @failure[fallback]
            end

            failure_state = @children[fallback].fetch(byte, 0)
            @failure[child] = failure_state
            @dictionary_suffix[child] =
              if @terminal[failure_state].empty?
                @dictionary_suffix[failure_state]
              else
                failure_state
              end
            queue << child
          end
        end
      end
    end

    AhoCorasick = MultiPatternMatcher
    MultiPatternSearcher = MultiPatternMatcher
  end
end
