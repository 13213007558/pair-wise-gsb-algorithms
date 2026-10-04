=begin rdoc
    This module implements search algorithms. Documentation is provided for each algorithm.
    
=end
module Algorithms::Search
  class AhoCorasickMatcher
    Match = Struct.new(:pattern_id, :start_byte, :end_byte)
    Node = Struct.new(:children, :transitions, :failure, :output_link, :depth, :patterns)

    # Builds an Aho-Corasick automaton for zero or more byte patterns.
    #
    # Patterns may be supplied as strings, in which case their index in the
    # array is used as the pattern ID, or as [pattern_id, pattern] pairs. The
    # same pattern may be registered more than once with different IDs.
    #
    # Empty patterns are not supported and raise ArgumentError because their
    # zero-width matches do not have a unique byte interval. Matching operates
    # on bytes, independently of the string's character encoding.
    #
    # Construction complexity is O(total pattern length) expected time.
    def initialize(patterns)
      raise ArgumentError, "patterns must be Enumerable" unless patterns.is_a?(Enumerable)

      @root = Node.new({}, {}, nil, nil, 0, [])

      patterns.to_a.each_with_index do |entry, registration_order|
        if entry.is_a?(Array) && entry.length == 2
          pattern_id, pattern = entry
        elsif entry.is_a?(String)
          pattern_id = registration_order
          pattern = entry
        else
          raise ArgumentError, "each pattern must be a String or [pattern_id, pattern] pair"
        end

        unless pattern.is_a?(String)
          raise ArgumentError, "pattern #{registration_order.inspect} must be a String"
        end
        raise ArgumentError, "empty patterns are not supported" if pattern.empty?

        node = @root
        pattern.each_byte do |byte|
          node = node.children[byte] ||= Node.new({}, {}, nil, nil, node.depth + 1, [])
        end
        node.patterns << [pattern_id, pattern.bytesize, registration_order]
      end

      build_failure_links
      @state = @root
      @position = 0
    end

    # Feeds the next chunk of the byte stream and returns every pattern match
    # that ends in this chunk, including matches that began in a previous
    # chunk. Match intervals are half-open: [start_byte, end_byte).
    #
    # Results are ordered by end_byte. When multiple matches end at the same
    # byte, they are ordered by pattern_id, then constructor registration
    # order. Pattern IDs must be mutually comparable. Feeding n bytes takes
    # O(n + z log p) expected time, where z is the number of returned matches
    # and p is the number of patterns that can end at one byte.
    def feed(chunk)
      raise ArgumentError, "chunk must be a String" unless chunk.is_a?(String)

      matches = []
      chunk.each_byte.with_index do |byte, index|
        @state = next_state(@state, byte)
        end_byte = @position + index + 1
        collect_matches(@state, end_byte, matches)
      end
      @position += chunk.bytesize
      matches
    end

    # Returns the matcher to the beginning of the stream. The built automaton
    # is retained and can be reused for another byte stream.
    def reset
      @state = @root
      @position = 0
      self
    end

    private

    def build_failure_links
      queue = []
      queue_index = 0
      @root.failure = @root

      @root.children.each_value do |child|
        child.failure = @root
        queue << child
      end

      while queue_index < queue.length
        node = queue[queue_index]
        queue_index += 1
        failure = node.failure
        node.output_link = failure.patterns.empty? ? failure.output_link : failure

        node.children.each do |byte, child|
          child.failure = next_state(failure, byte)
          queue << child
        end
      end
    end

    def next_state(node, byte)
      path = []

      until node.children.key?(byte)
        if node == @root
          target = @root
          break
        end
        if node.transitions.key?(byte)
          target = node.transitions[byte]
          break
        end
        path << node
        node = node.failure
      end
      target ||= node.children[byte]
      path.each { |current| current.transitions[byte] = target }
      target
    end

    def collect_matches(state, end_byte, matches)
      ending_here = []
      node = state

      until node == @root
        ending_here.concat(node.patterns)
        node = node.output_link
        break if node.nil?
      end

      ending_here.sort_by! do |pattern_id, _length, registration_order|
        [pattern_id, registration_order]
      end
      ending_here.each do |pattern_id, length, _registration_order|
        matches << Match.new(pattern_id, end_byte - length, end_byte)
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
