$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require 'algorithms'

if defined?(Algorithms::String::MultiPatternMatcher)
  describe Algorithms::String::MultiPatternMatcher do
    let(:patterns) { ['he', 'she', 'hers', 'his'] }
    let(:input) { 'she sells his hers' }
    let(:matcher) { described_class.new(patterns) }

    def split_every_way(value)
      [[value]].concat(
        (1...value.bytesize).map do |size|
          value.each_byte.each_slice(size).map { |bytes| bytes.pack('C*') }
        end
      )
    end

    it 'returns the pattern identity and byte offsets' do
      matches = matcher.scan(input)

      expect(matches.map { |match| [match.pattern_id, match.start_offset, match.end_offset] }).to eq([
        ['she', 0, 3],
        ['he', 1, 3],
        ['his', 10, 13],
        ['he', 14, 16],
        ['hers', 14, 18],
      ])
      expect(matches.map { |match| input[match.start_offset...match.end_offset] }).to eq([
        'she', 'he', 'his', 'he', 'hers'
      ])
    end

    it 'matches the same when the input is divided at every byte boundary' do
      expected = matcher.scan(input)

      split_every_way(input).each do |chunks|
        scanner = matcher.new_scanner
        found = chunks.flat_map { |chunk| scanner.scan(chunk) }

        expect(scanner.finish).to eq(expected)
        expect(found).to eq(expected)
      end
    end

    it 'keeps duplicate and suffix-overlapping matches separate' do
      duplicate_matcher = described_class.new([
        ['a', :first_a],
        'a',
        ['ba', :ba],
        ['a', :last_a],
      ])

      expect(duplicate_matcher.scan('ba').map { |match|
        [match.pattern_id, match.start_offset, match.end_offset, match.pattern_index]
      }).to eq([
        [:ba, 0, 2, 2],
        [:first_a, 1, 2, 0],
        ['a', 1, 2, 1],
        [:last_a, 1, 2, 3],
      ])
    end

    it 'supports independent sessions over one compiled pattern table' do
      first = matcher.new_scanner
      second = matcher.new_scanner

      expect(first.scan('sh')).to eq([])
      expect(second.scan('he')).to contain_exactly(
        have_attributes(pattern_id: 'he', start_offset: 0, end_offset: 2)
      )
      expect(first.scan('e').map { |match|
        [match.pattern_id, match.start_offset, match.end_offset]
      }).to eq([
        ['she', 0, 3],
        ['he', 1, 3],
      ])
      expect(first.offset).to eq(3)
      expect(second.offset).to eq(2)
    end

    it 'rejects empty patterns directly and in pairs or hashes' do
      expect { described_class.new(['ok', '']) }.to raise_error(ArgumentError)
      expect { described_class.new([['', :id]]) }.to raise_error(ArgumentError)
      expect { described_class.new([{ pattern: '', pattern_id: :id }]) }.to raise_error(ArgumentError)
    end

    it 'works with UTF-8 strings split between multibyte characters' do
      utf8_matcher = described_class.new(['é他'])
      bytes = 'aé他z'.b.bytes
      scanner = utf8_matcher.new_scanner
      found = bytes.each_slice(2).map { |part| scanner.scan(part.pack('C*').force_encoding('UTF-8')) }.flatten

      expect(found.map { |match| [match.start_offset, match.end_offset] }).to eq([[1, 6]])
      expect(scanner.finish).to eq(found)
    end

    it 'provides a compile factory and Aho-Corasick alias' do
      compiled = described_class.compile(patterns)
      aliased = Algorithms::String::AhoCorasick.new(patterns)

      expect(compiled).to be_a(described_class)
      expect(aliased).to be_a(described_class)
      expect(compiled.scan(input).map(&:deconstruct)).to eq(
        aliased.scan(input).map(&:deconstruct)
      )
    end
  end
end
