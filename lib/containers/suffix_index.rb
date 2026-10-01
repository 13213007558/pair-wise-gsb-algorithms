=begin rdoc
    A SuffixIndex supports appending bytes incrementally and answers substring
    existence, occurrence count, and distinct non-empty substring count queries.

    Positions and equality are defined by bytes. Inputs are converted to strings
    with #to_s and then treated as binary data, so multibyte characters do not
    create ambiguous substring boundaries.

    The index is implemented with a suffix automaton. Statistics are settled
    lazily on first query after an append; appending invalidates any previously
    settled counts.
=end
class Containers::SuffixIndex
  # Creates a new SuffixIndex. An initial value is optional and is converted to
  # a string with #to_s before being indexed byte by byte.
  #
  #   index = Containers::SuffixIndex.new("aaa")
  #   index.append("a")
  #   index.occurrence_count("aa") #=> 3
  def initialize(string = "")
    @states = []
    create_state(0)
    @states[0][:link] = -1
    @last = 0
    @length = 0
    @dirty = false
    @distinct_substring_count = 0
    append(string)
  end

  # Appends a value byte by byte. The value is converted to a string with #to_s.
  # Appending an empty value leaves the index unchanged. Returns self.
  #
  # Amortized complexity: O(k) for k appended bytes.
  def append(string = "")
    string = string.to_s.b
    return self if string.empty?

    string.each_byte { |byte| append_byte(byte) }
    self
  end
  alias_method :<<, :append

  # Returns true if the non-empty byte substring occurs in the indexed bytes.
  #
  # Complexity: O(m), where m is the substring length in bytes.
  def has_substring?(substring)
    substring = substring.to_s.b
    return false if substring.empty?
    !find_state(substring).nil?
  end
  alias_method :[], :has_substring?

  # Returns the number of starting byte positions at which the non-empty byte
  # substring occurs. Overlapping occurrences are counted separately.
  #
  # Counts are propagated through suffix links when needed, then any append
  # invalidates that result.
  def occurrence_count(substring)
    substring = substring.to_s.b
    return 0 if substring.empty?
    state = find_state(substring)
    return 0 unless state

    settle_statistics
    @states[state][:occurrences]
  end
  alias_method :count, :occurrence_count

  # Returns the number of distinct non-empty byte substrings in the indexed
  # bytes.
  #
  # The result is calculated when needed and recalculated after any append.
  def distinct_substring_count
    settle_statistics
    @distinct_substring_count
  end
  alias_method :distinct_count, :distinct_substring_count

  private

  def create_state(length)
    @states << {
      :length => length,
      :link => 0,
      :transitions => {},
      :occurrences => 0,
      :terminal => false
    }
    @states.size - 1
  end

  def append_byte(byte)
    current = create_state(@states[@last][:length] + 1)
    @states[current][:occurrences] = 1
    @states[current][:terminal] = true
    @length += 1
    @dirty = true

    state = @last
    while state != -1 && !@states[state][:transitions].key?(byte)
      @states[state][:transitions][byte] = current
      state = @states[state][:link]
    end

    if state == -1
      @states[current][:link] = 0
    else
      existing = @states[state][:transitions][byte]
      if @states[state][:length] + 1 == @states[existing][:length]
        @states[current][:link] = existing
      else
        clone = create_state(@states[state][:length] + 1)
        @states[clone][:transitions] = @states[existing][:transitions].dup
        @states[clone][:link] = @states[existing][:link]

        while state != -1 && @states[state][:transitions][byte] == existing
          @states[state][:transitions][byte] = clone
          state = @states[state][:link]
        end

        @states[existing][:link] = clone
        @states[current][:link] = clone
      end
    end

    @last = current
  end

  def find_state(substring)
    state = 0
    substring.each_byte do |byte|
      state = @states[state][:transitions][byte]
      return nil unless state
    end
    state
  end

  def settle_statistics
    return unless @dirty

    buckets = Array.new(@length + 1) { [] }
    @states.each_with_index do |state, id|
      buckets[state[:length]] << id
    end

    order = []
    buckets.each { |bucket| order.concat(bucket) }

    @states.each { |state| state[:occurrences] = state[:terminal] ? 1 : 0 }

    order.reverse_each do |state_id|
      state = @states[state_id]
      link = state[:link]
      next unless link >= 0
      @states[link][:occurrences] += state[:occurrences]
    end

    @distinct_substring_count = @states.inject(0) do |count, state|
      next count if state[:link] == -1
      count + state[:length] - @states[state[:link]][:length]
    end
    @dirty = false
  end
end

Containers::IncrementalSuffixIndex = Containers::SuffixIndex
