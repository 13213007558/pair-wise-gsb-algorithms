$: << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')
require 'algorithms'

describe Algorithms::Search::AhoCorasick do
  let(:patterns) { ["he", "she", "hers", "his"] }
  let(:matcher) { described_class.new(patterns) }

  def triples(matches)
    matches.map { |m| [m.pattern_id, m.start_offset, m.end_offset] }
  end

  it "rejects empty, nil, and non-string patterns" do
    expect { described_class.new([]) }.to raise_error(ArgumentError)
    expect { described_class.new(nil) }.to raise_error(ArgumentError)
    expect { described_class.new([""]) }.to raise_error(ArgumentError)
    expect { described_class.new(["he", ""]) }.to raise_error(ArgumentError)
    expect { described_class.new([nil]) }.to raise_error(ArgumentError)
    expect { described_class.new([:he]) }.to raise_error(ArgumentError)
  end

  it "finds all overlapping matches with pattern identity and offsets" do
    expect(triples(matcher.scan("ushers"))).to eql([
      [1, 1, 4], # she
      [0, 2, 4], # he
      [2, 2, 6], # hers
    ])
    expect(triples(matcher.scan("his"))).to eql([[3, 0, 3]])
    expect(matcher.scan("nope")).to be_empty
  end

  it "exposes the matched pattern itself" do
    match = matcher.scan("she").first
    expect(match.pattern_id).to eql(1)
    expect(match.pattern).to eql("she")
  end

  it "reports duplicate patterns under distinct identities" do
    matches = described_class.new(["he", "he"]).scan("hehe")
    expect(matches.map(&:pattern_id)).to eql([0, 1, 0, 1])
    expect(matches.map(&:pattern)).to eql(["he", "he", "he", "he"])
  end

  it "reports patterns that are suffixes of other patterns" do
    matches = described_class.new(["abc", "bc", "c"]).scan("abc")
    expect(matches.map(&:pattern_id)).to eql([0, 1, 2])
    expect(matches.map(&:start_offset)).to eql([0, 1, 2])
    expect(matches.map(&:end_offset)).to eql([3, 3, 3])
  end

  it "keeps scan sessions independent of each other" do
    session1 = matcher.new_session
    session2 = matcher.new_session
    expect(session1.feed("ush")).to be_empty
    expect(triples(session2.feed("ushers"))).to eql([[1, 1, 4], [0, 2, 4], [2, 2, 6]])
    expect(triples(session1.feed("ers"))).to eql([[1, 1, 4], [0, 2, 4], [2, 2, 6]])
  end

  it "produces identical results for every two-chunk split" do
    text = "ushers his she hershe"
    expected = matcher.scan(text)
    (0..text.bytesize).each do |i|
      session = matcher.new_session
      got = session.feed(text.byteslice(0, i))
      got.concat(session.feed(text.byteslice(i..-1) || ""))
      got.concat(session.finish)
      expect(got).to eql(expected), "split at #{i} diverged"
    end
  end

  it "produces identical results for random chunkings" do
    text = ("ushers" * 20) + "his" + ("she" * 10)
    expected = matcher.scan(text)
    10.times do
      session = matcher.new_session
      got = []
      pos = 0
      while pos < text.bytesize
        length = rand(1..7)
        got.concat(session.feed(text.byteslice(pos, length)))
        pos += length
      end
      got.concat(session.finish)
      expect(got).to eql(expected)
    end
  end

  it "shares the compiled table across one-shot scans" do
    first = matcher.scan("ushers")
    second = matcher.scan("ushers")
    expect(first).to eql(second)
    expect(matcher.patterns).to eql(patterns)
    expect(matcher.patterns).to be_frozen
  end

  it "resets a finished session for reuse" do
    session = matcher.new_session
    session.feed("ushers")
    expect(session.finish).to eql([])
    expect(triples(session.feed("his"))).to eql([[3, 0, 3]])
  end

  it "reports byte offsets for multibyte input" do
    multi = described_class.new(["他", "好人"])
    matches = multi.scan("x他y好人们")
    expect(triples(matches)).to eql([
      [0, 1, 4],  # 他
      [1, 5, 11], # 好人
    ])
  end

  it "rejects non-string chunks" do
    expect { matcher.new_session.feed(nil) }.to raise_error(ArgumentError)
  end
end
