=begin rdoc
    A suffix automaton is an incrementally extensible substring index. Unlike
    Containers::SuffixArray, which rebuilds its whole index for every new string,
    a SuffixAutomaton lets you append more text (e.g. log lines arriving over
    time) in O(1) amortized per byte while continuing to answer substring
    queries against everything indexed so far.

    Supported queries:
    * has_substring?  - does the pattern occur in the indexed text?
    * count_substring - how many times does it occur? Overlapping occurrences
                        are counted separately ("aa" occurs 3 times in "aaaa").
    * distinct_substrings - how many different non-empty substrings exist?

    All matching is defined over bytes: input is converted with String#b and
    compared byte by byte, so positions and equality never depend on encoding
    boundaries. Occurrence and distinct-substring statistics are computed
    lazily when first queried and are recomputed after every #append, so
    queries never observe stale counts.

=end
class Containers::SuffixAutomaton
  # A single automaton state. +len+ is the longest string in its endpos
  # equivalence class, +link+ the suffix link, +trans+ the byte transitions,
  # and +terminal+ whether some prefix of the text ends in this state.
  State = Struct.new(:len, :link, :trans, :terminal)

  # Creates a new SuffixAutomaton, optionally seeded with an initial string.
  # Objects of any class implementing #to_s can be passed in. Unlike
  # Containers::SuffixArray, an empty (or omitted) initial string is allowed
  # since text is expected to be added later with #append.
  #
  #   sam = Containers::SuffixAutomaton.new("abra")
  #   sam << "cadabra"
  #   sam.has_substring?("abracadabra") #=> true
  def initialize(string = "")
    @states = [State.new(0, -1, {}, false)]
    @last = 0
    @length = 0
    @stats_dirty = true
    append(string) unless string.to_s.empty?
  end

  # Appends text to the index. Queries issued afterwards reflect the combined
  # text; previously computed statistics are discarded and recomputed on the
  # next query. Returns self so appends can be chained.
  #
  # Complexity: O(k) amortized for k appended bytes
  #
  #   sam = Containers::SuffixAutomaton.new
  #   sam.append("log line one\n").append("log line two\n")
  def append(string)
    string.to_s.b.each_byte { |byte| extend(byte) }
    self
  end
  alias_method :<<, :append

  # Returns the number of bytes indexed so far.
  attr_reader :length
  alias_method :size, :length

  # Returns true if the substring occurs in the indexed text, false otherwise.
  # The empty substring never matches.
  #
  # Complexity: O(m) for a pattern of m bytes
  #
  #   sam = Containers::SuffixAutomaton.new("abracadabra")
  #   sam.has_substring?("abra") #=> true
  #   sam.has_substring?("nope") #=> false
  def has_substring?(substring)
    !find_state(substring).nil?
  end
  alias_method :[], :has_substring?

  # Returns how many times the substring occurs in the indexed text.
  # Overlapping occurrences are counted separately, so "aa" occurs 3 times
  # in "aaaa". Returns 0 for substrings that do not occur, including the
  # empty substring.
  #
  #   sam = Containers::SuffixAutomaton.new("aaaa")
  #   sam.count_substring("aa") #=> 3
  def count_substring(substring)
    state = find_state(substring)
    return 0 if state.nil?
    recompute_stats if @stats_dirty
    @occurrences[state]
  end
  alias_method :occurrences, :count_substring

  # Returns the total number of different non-empty substrings of the
  # indexed text.
  #
  #   sam = Containers::SuffixAutomaton.new("aaaa")
  #   sam.distinct_substrings #=> 4 ("a", "aa", "aaa", "aaaa")
  def distinct_substrings
    recompute_stats if @stats_dirty
    @distinct
  end

  private

  def extend(byte)
    @stats_dirty = true
    @length += 1
    cur = @states.size
    @states << State.new(@states[@last].len + 1, 0, {}, true)
    p = @last
    while p != -1 && !@states[p].trans.key?(byte)
      @states[p].trans[byte] = cur
      p = @states[p].link
    end
    if p == -1
      @states[cur].link = 0
    else
      q = @states[p].trans[byte]
      if @states[p].len + 1 == @states[q].len
        @states[cur].link = q
      else
        clone = @states.size
        @states << State.new(@states[p].len + 1, @states[q].link, @states[q].trans.dup, false)
        while p != -1 && @states[p].trans[byte] == q
          @states[p].trans[byte] = clone
          p = @states[p].link
        end
        @states[q].link = @states[cur].link = clone
      end
    end
    @last = cur
  end

  # Walks the automaton along the pattern's bytes and returns the state
  # reached, or nil if the pattern does not occur.
  def find_state(substring)
    bytes = substring.to_s.b
    return nil if bytes.empty?
    state = 0
    bytes.each_byte do |byte|
      state = @states[state].trans[byte]
      return nil if state.nil?
    end
    state
  end

  # Recomputes occurrence counts and the distinct-substring total from the
  # current automaton. Occurrence counts are found by propagating each
  # state's terminal marker up the suffix-link tree in order of decreasing
  # length; the distinct total is the sum of len(state) - len(link) over all
  # non-root states.
  def recompute_stats
    order = (1...@states.size).sort_by { |i| -@states[i].len }
    @occurrences = Array.new(@states.size, 0)
    @states.each_with_index { |state, i| @occurrences[i] = 1 if state.terminal }
    order.each do |i|
      link = @states[i].link
      @occurrences[link] += @occurrences[i] if link >= 0
    end
    @distinct = 0
    order.each { |i| @distinct += @states[i].len - @states[@states[i].link].len }
    @stats_dirty = false
  end
end
