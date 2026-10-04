=begin rdoc
    This module implements search algorithms. Documentation is provided for each algorithm.
    
=end
module Algorithms::Search

  # A value returned by AhoCorasickMatcher. Byte intervals are half-open,
  # containing start_byte but excluding end_byte.
  AhoCorasickMatch = Struct.new(:pattern_id, :start_byte, :end_byte)

  AhoCorasickNode = Struct.new(:children, :failure, :output, :pattern_ids,
                               :depth)

  # Aho-Corasick multi-pattern substring search. Build the automaton once, then
  # feed a byte stream in arbitrary chunks.
  #
  # Patterns are supplied as [id, pattern] pairs. Byte offsets are absolute and
  # half-open. Empty patterns are rejected because they would match at every
  # stream position. Matches are ordered by their ending byte; when several
  # matches end at the same byte, the longest match is reported first, followed
  # by its shorter suffix matches. Identical patterns retain their construction
  # order and may therefore use different IDs.
  #
  # Construction takes O(total pattern length). Streaming takes O(bytes read +
  # matches reported) amortized time.
  #
  #   matcher = Algorithms::Search::AhoCorasickMatcher.new([
  #     [1, "he"], [2, "she"], [3, "his"], [4, "hers"]
  #   ])
  #   matcher.feed("us").map(&:to_a)  #=> []
  #   matcher.feed("he").map(&:to_a)  #=> [[2, 1, 4], [1, 2, 4]]
  #   matcher.feed("rs").map(&:to_a)  #=> [[4, 2, 6]]
  #
  # "she" and "he" share a suffix, while "he" and "hers" share a prefix. The
  # final "hers" match also spans all three chunks.
  class AhoCorasickMatcher
    def initialize(patterns)
      @root = AhoCorasickNode.new({}, nil, nil, [], 0)
      @root.failure = @root

      patterns.each_with_index do |entry, index|
        pattern_id, pattern =
          if entry.is_a?(Array) && entry.length == 2
            entry
          else
            [index, entry]
          end

        unless pattern.is_a?(String)
          raise TypeError, "patterns must be Strings"
        end
        if pattern.bytesize.zero?
          raise ArgumentError, "empty patterns are not supported"
        end

        node = @root
        pattern.each_byte do |byte|
          node =
            node.children[byte] ||=
              AhoCorasickNode.new({}, @root, nil, [], node.depth + 1)
        end
        node.pattern_ids << pattern_id
      end

      build_failure_links
      reset
    end

    # Feeds one chunk of bytes and returns every match completed in that chunk.
    # Match offsets remain absolute across successive calls. If a block is
    # given, each match is yielded as well as returned.
    def feed(chunk)
      unless chunk.is_a?(String)
        raise TypeError, "chunks must be Strings"
      end

      matches = []
      chunk.each_byte do |byte|
        while @state != @root && !@state.children.key?(byte)
          @state = @state.failure
        end
        @state = @state.children[byte] || @root

        end_byte = @position + 1
        node = @state
        while node
          node.pattern_ids.each do |pattern_id|
            match = AhoCorasickMatch.new(pattern_id,
                                        end_byte - node.depth,
                                        end_byte)
            yield match if block_given?
            matches << match
          end
          node = node.output
        end

        @position = end_byte
      end
      matches
    end

    # Resets matcher state without rebuilding the automaton.
    def reset
      @state = @root
      @position = 0
      self
    end

    private

    def build_failure_links
      queue = @root.children.values
      index = 0

      while index < queue.length
        node = queue[index]
        index += 1

        node.children.each do |byte, child|
          fallback = node.failure
          while fallback != @root && !fallback.children.key?(byte)
            fallback = fallback.failure
          end

          candidate = fallback.children[byte]
          child.failure =
            if candidate && candidate != child
              candidate
            else
              @root
            end
          child.output =
            if child.failure.pattern_ids.empty?
              child.failure.output
            else
              child.failure
            end
          queue << child
        end
      end
    end
  end
  # Binary Search: This search finds an item in log(n) time provided that the container is already sorted.
  # The method returns the item if it is found, or nil if it is not. If there are duplicates, the first one
  # found is returned, and this is not guaranteed to be the smallest or largest item.
  #
  # Complexity: O(lg N)
  # 
  #   Algorithms::Search.binary_search([1, 2, 3], 1) #=> 1
  #   Algorithms::Search.binary_search([1, 2, 3], 4) #=> nil
  def self.binary_search(container, item)
    return nil if item.nil?
    low = 0
    high = container.size - 1
    while low <= high
      mid = (low + high) / 2
      val = container[mid]
      if val > item
        high = mid - 1
      elsif val < item
        low = mid + 1
      else
        return val
      end
    end
    nil
  end
  
  # Knuth-Morris-Pratt Algorithm substring search algorithm: Efficiently finds the starting position of a 
  # substring in a string. The algorithm calculates the best position to resume searching from if a failure
  # occurs.
  # 
  # The method returns the index of the starting position in the string where the substring is found. If there
  # is no match, nil is returned.
  #
  # Complexity: O(n + k), where n is the length of the string and k is the length of the substring.
  #
  #   Algorithms::Search.kmp_search("ABC ABCDAB ABCDABCDABDE", "ABCDABD") #=> 15
  #   Algorithms::Search.kmp_search("ABC ABCDAB ABCDABCDABDE", "ABCDEF") #=> nil
  def self.kmp_search(string, substring)
    return nil if string.nil? or substring.nil?
    
    # create failure function table
    pos = 2
    cnd = 0
    failure_table = [-1, 0]
    while pos < substring.length
      if substring[pos - 1] == substring[cnd]
        failure_table[pos] = cnd + 1
        pos += 1
        cnd += 1
      elsif cnd > 0
        cnd = failure_table[cnd]
      else
        failure_table[pos] = 0
        pos += 1
      end
    end

    m = i = 0
    while m + i < string.length
      if substring[i] == string[m + i]
        i += 1
        return m if i == substring.length
      else
        m = m + i - failure_table[i]
        i = failure_table[i] if i > 0
      end
    end
    return nil
  end
  
  # Allows kmp_search to be called as an instance method in classes that include the Search module.
  #
  #   class String; include Algorithms::Search; end
  #   "ABC ABCDAB ABCDABCDABDE".kmp_search("ABCDABD") #=> 15
  def kmp_search(substring)
    Algorithms::Search.kmp_search(self, substring)
  end
  
end
