$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe "empty suffix automaton" do
  it "should initialize without arguments" do
    sam = Containers::SuffixAutomaton.new
    expect(sam.length).to eql(0)
    expect(sam.has_substring?("a")).to be false
    expect(sam.count_substring("a")).to eql(0)
    expect(sam.distinct_substrings).to eql(0)
  end

  it "should not match the empty substring" do
    sam = Containers::SuffixAutomaton.new("abc")
    expect(sam.has_substring?("")).to be false
    expect(sam.count_substring("")).to eql(0)
  end
end

describe "non-empty suffix automaton" do
  before(:each) do
    @sam = Containers::SuffixAutomaton.new("abracadabra")
  end

  it "should has_substring? each possible substring" do
    expect(@sam.has_substring?("a")).to be true
    expect(@sam.has_substring?("abra")).to be true
    expect(@sam.has_substring?("abracadabra")).to be true
    expect(@sam.has_substring?("acadabra")).to be true
    expect(@sam.has_substring?("bra")).to be true
    expect(@sam.has_substring?("racadabra")).to be true
    expect(@sam["cadabra"]).to be true
  end

  it "should not has_substring? substrings it does not have" do
    expect(@sam.has_substring?("nope")).to be false
    expect(@sam.has_substring?("abracadabras")).to be false
    expect(@sam.has_substring?(nil)).to be false
  end

  it "should count occurrences including overlaps" do
    expect(@sam.count_substring("a")).to eql(5)
    expect(@sam.count_substring("abra")).to eql(2)
    expect(@sam.count_substring("bra")).to eql(2)
    expect(@sam.count_substring("nope")).to eql(0)
  end

  it "should count distinct non-empty substrings" do
    expect(@sam.distinct_substrings).to eql(54)
  end

  it "should work with numbers (calls to_s)" do
    number = Containers::SuffixAutomaton.new(123456789)
    expect(number[1]).to be true
    expect(number.count_substring(12)).to eql(1)
    expect(number.has_substring?(13)).to be false
  end
end

describe "overlapping occurrences" do
  it "should recount overlapping hits from character positions" do
    sam = Containers::SuffixAutomaton.new("aaaa")
    expect(sam.count_substring("a")).to eql(4)
    expect(sam.count_substring("aa")).to eql(3)
    expect(sam.count_substring("aaa")).to eql(2)
    expect(sam.count_substring("aaaa")).to eql(1)
    expect(sam.count_substring("aaaaa")).to eql(0)
    expect(sam.distinct_substrings).to eql(4)
  end
end

describe "incremental appends" do
  it "should answer queries identically to a from-scratch index" do
    incremental = Containers::SuffixAutomaton.new
    incremental.append("abra").append("cad").append("abra")
    from_scratch = Containers::SuffixAutomaton.new("abracadabra")
    %w[a ab bra abra cad abracadabra racadabra nope abracadabras].each do |sub|
      expect(incremental.has_substring?(sub)).to eql(from_scratch.has_substring?(sub))
      expect(incremental.count_substring(sub)).to eql(from_scratch.count_substring(sub))
    end
    expect(incremental.distinct_substrings).to eql(from_scratch.distinct_substrings)
    expect(incremental.length).to eql(11)
  end

  it "should support << as an append alias" do
    sam = Containers::SuffixAutomaton.new
    expect(sam << "log" << "ger").to be(sam)
    expect(sam.has_substring?("logger")).to be true
  end

  it "should not reuse stale counts after appending" do
    sam = Containers::SuffixAutomaton.new("aa")
    expect(sam.count_substring("a")).to eql(2)
    expect(sam.count_substring("aa")).to eql(1)
    expect(sam.distinct_substrings).to eql(2)
    sam.append("aa")
    expect(sam.count_substring("a")).to eql(4)
    expect(sam.count_substring("aa")).to eql(3)
    expect(sam.distinct_substrings).to eql(4)
  end

  it "should keep answering queries recorded before an append" do
    sam = Containers::SuffixAutomaton.new("error: disk full")
    expect(sam.has_substring?("error")).to be true
    sam.append("\nwarning: disk almost full")
    expect(sam.has_substring?("error")).to be true
    expect(sam.has_substring?("full\nwarning")).to be true
    expect(sam.count_substring("disk")).to eql(2)
  end
end

describe "byte semantics" do
  it "should match by bytes regardless of encoding boundaries" do
    sam = Containers::SuffixAutomaton.new("h\u00e9llo") # "héllo" in UTF-8
    expect(sam.length).to eql(6)
    expect(sam.has_substring?("h\u00e9")).to be true
    expect(sam.count_substring("\u00e9")).to eql(1)
    # A lone continuation byte is a valid byte-level pattern
    expect(sam.has_substring?("\xA9".b)).to be true
    expect(sam.has_substring?("\xA9\x6C".b)).to be true
  end
end

describe "brute force cross-check" do
  def brute_count(text, pattern)
    count = 0
    (0..text.bytesize - pattern.bytesize).each do |i|
      count += 1 if text.byteslice(i, pattern.bytesize) == pattern
    end
    count
  end

  def brute_distinct(text)
    subs = {}
    (0...text.bytesize).each do |i|
      (i + 1..text.bytesize).each do |j|
        subs[text.byteslice(i...j)] = true
      end
    end
    subs.size
  end

  it "should match naive counts for text appended in chunks" do
    chunks = ["banana", " split", " and banana", "ana"]
    text = chunks.join.b
    sam = Containers::SuffixAutomaton.new
    chunks.each { |chunk| sam.append(chunk) }
    patterns = ["a", "an", "ana", "banana", " split", "na ", "and", "xyz", "banana split and banana"]
    patterns.each do |pattern|
      pattern = pattern.b
      expect(sam.has_substring?(pattern)).to eql(brute_count(text, pattern) > 0)
      expect(sam.count_substring(pattern)).to eql(brute_count(text, pattern))
    end
    expect(sam.distinct_substrings).to eql(brute_distinct(text))
  end
end
