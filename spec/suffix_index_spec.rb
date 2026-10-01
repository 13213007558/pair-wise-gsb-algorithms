$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe "empty suffix index" do
  before(:each) do
    @index = Containers::SuffixIndex.new
  end

  it "supports empty and nil queries" do
    expect(@index.has_substring?("")).to be false
    expect(@index.has_substring?(nil)).to be false
    expect(@index.occurrence_count("")).to eql(0)
    expect(@index.occurrence_count(nil)).to eql(0)
    expect(@index.distinct_substring_count).to eql(0)
  end

  it "can build the index by appending" do
    @index.append("abra")
    expect(@index.has_substring?("bra")).to be true
    expect(@index.occurrence_count("bra")).to eql(1)
    expect(@index.distinct_substring_count).to eql(9)

    @index.append("cadabra")
    expect(@index.has_substring?("abra")).to be true
    expect(@index.occurrence_count("abra")).to eql(2)
    expect(@index.distinct_substring_count).to eql(54)
  end
end

describe "non-empty suffix index" do
  before(:each) do
    @index = Containers::SuffixIndex.new("aaa")
  end

  it "counts overlapping occurrences from byte starting positions" do
    expect(@index.occurrence_count("aa")).to eql(2)
    expect(@index.has_substring?("aa")).to be true

    @index.append("a")
    expect(@index.occurrence_count("aa")).to eql(3)
    expect(@index["aa"]).to be true
  end

  it "discards settled occurrence counts before another append" do
    expect(@index.occurrence_count("a")).to eql(3)
    @index.append("a")
    expect(@index.occurrence_count("a")).to eql(4)
    @index.append("a")
    expect(@index.occurrence_count("a")).to eql(5)
    expect(@index.occurrence_count("aa")).to eql(4)
  end

  it "recomputes distinct non-empty substrings after an append" do
    expect(@index.distinct_substring_count).to eql(3)
    @index.append("a")
    expect(@index.distinct_substring_count).to eql(4)
    @index.append("b")
    expect(@index.distinct_substring_count).to eql(9)
  end

  it "does not keep missing matches after they are appended" do
    expect(@index.has_substring?("ab")).to be false
    expect(@index.occurrence_count("ab")).to eql(0)
    @index.append("b")
    expect(@index.has_substring?("ab")).to be true
    expect(@index.occurrence_count("ab")).to eql(1)
  end

  it "supports values converted with to_s" do
    index = Containers::SuffixIndex.new(123)
    expect(index.occurrence_count(23)).to eql(1)
    index.append(45)
    expect(index.occurrence_count(34)).to eql(1)
  end

  it "uses byte positions and byte equality" do
    text = "\u00e9\u00e9".dup.force_encoding("UTF-8")
    first_character = text.byteslice(0, 2)
    index = Containers::SuffixIndex.new(first_character)
    pattern = first_character.byteslice(0, 1)

    expect(index.occurrence_count(pattern)).to eql(1)
    index.append(text.byteslice(2, 2))
    expect(index.occurrence_count(pattern)).to eql(2)
    expect(index.distinct_substring_count).to eql(7)
  end

  it "is available through the incremental alias" do
    expect(Containers::IncrementalSuffixIndex).to eql(Containers::SuffixIndex)
  end
end
