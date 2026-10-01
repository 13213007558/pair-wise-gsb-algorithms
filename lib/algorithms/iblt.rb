require 'digest'
require 'json'

module Algorithms
  # Invertible Bloom Lookup Table for set reconciliation.
  #
  # Insertions use set semantics: adding the same fixed-width unsigned integer
  # more than once to one summary has no additional effect. Subtracting two
  # compatible summaries yields a third summary without changing either input.
  # Choose table_size above the expected number of differing IDs with margin;
  # decode returns :incomplete with residual cells if peeling cannot finish.
  class IBLT
    class Error < StandardError; end

    Cell = Struct.new(:count, :key_sum, :key_checksum)
    ResidualCell = Struct.new(:index, :count, :key_sum, :key_checksum)

    DecodeResult = Struct.new(:status, :left_only, :right_only, :residual) do
      def complete?
        status == :complete
      end

      def incomplete?
        status == :incomplete
      end

      def identical?
        complete? && left_only.empty? && right_only.empty?
      end
      alias_method :no_difference?, :identical?

      def partially_recovered?
        incomplete? && (!left_only.empty? || !right_only.empty?)
      end
    end

    DIGEST_ID = "sha256-v1".freeze
    SERIALIZATION_FORMAT = "algorithms-iblt".freeze
    SERIALIZATION_VERSION = 1

    attr_reader :table_size, :hash_count, :key_bytes, :seed, :digest_id

    def initialize(table_size:, hash_count: 3, key_bytes: 8, seed: 0)
      @table_size = validate_positive_integer(table_size, :table_size)
      @hash_count = validate_positive_integer(hash_count, :hash_count)
      @key_bytes = validate_positive_integer(key_bytes, :key_bytes)
      @seed = validate_integer(seed, :seed)
      @digest_id = DIGEST_ID

      if table_size > (2 ** 32) - 1
        raise ArgumentError, "table_size must be less than 2^32"
      end
      if hash_count > table_size
        raise ArgumentError, "hash_count cannot be larger than table_size"
      end
      unless key_bytes.between?(1, 64)
        raise ArgumentError, "key_bytes must be between 1 and 64"
      end
      unless seed.between?(0, (2 ** 64) - 1)
        raise ArgumentError, "seed must be an unsigned 64-bit integer"
      end

      @key_modulus = 2 ** (key_bytes * 8)
      @checksum_modulus = 2 ** 64
      @cells = Array.new(table_size) { Cell.new(0, 0, 0) }
      @seen = {}
    end

    def self.from_h(data)
      unless data.is_a?(Hash)
        raise Error, "IBLT payload must be a Hash"
      end

      if data["format"] != SERIALIZATION_FORMAT
        raise Error, "unexpected IBLT serialization format"
      end
      if data["version"] != SERIALIZATION_VERSION
        raise Error, "unsupported IBLT serialization version"
      end
      if data["digest"] != DIGEST_ID
        raise Error, "unsupported IBLT digest"
      end

      iblt = new(
        table_size: fetch_integer(data, "table_size"),
        hash_count: fetch_integer(data, "hash_count"),
        key_bytes: fetch_integer(data, "key_bytes"),
        seed: fetch_integer(data, "seed")
      )

      cells = data["cells"]
      unless cells.is_a?(Array) && cells.size == iblt.table_size
        raise Error, "IBLT cells must contain exactly table_size entries"
      end

      iblt.send(:cells).replace(cells.each_with_index.map do |cell, index|
        unless cell.is_a?(Array) && cell.size == 3 && cell.all? { |value| value.is_a?(Integer) }
          raise Error, "IBLT cell #{index} must contain three integers"
        end

        count, key_sum, key_checksum = cell
        unless key_sum.between?(0, iblt.send(:key_modulus) - 1) &&
               key_checksum.between?(0, iblt.send(:checksum_modulus) - 1)
          raise Error, "IBLT cell #{index} contains an out-of-range value"
        end

        Cell.new(count, key_sum, key_checksum)
      end)

      iblt.instance_variable_set(:@seen, nil)
      iblt
    end

    def self.from_json(json)
      from_h(JSON.parse(json))
    end

    def self.fetch_integer(data, key)
      value = data.fetch(key)
      unless value.is_a?(Integer)
        raise Error, "IBLT #{key} must be an integer"
      end
      value
    rescue KeyError
      raise Error, "IBLT payload is missing #{key}"
    end
    private_class_method :fetch_integer

    def insert(id)
      ensure_locally_constructed!
      validate_id!(id)
      return false if @seen.key?(id)

      digest = digest_for(id)
      checksum = checksum_for(id, digest)
      positions_for(id, digest).each do |index|
        cell = @cells[index]
        cell.count += 1
        cell.key_sum = mask_key(cell.key_sum + id)
        cell.key_checksum = mask_checksum(cell.key_checksum + checksum)
      end

      @seen[id] = true
      true
    end
    alias_method :add, :insert
    alias_method :<<, :insert

    def difference(other)
      ensure_compatible!(other)

      result = self.class.new(
        table_size: table_size,
        hash_count: hash_count,
        key_bytes: key_bytes,
        seed: seed
      )
      result.instance_variable_set(:@seen, nil)

      result.cells.replace(@cells.each_with_index.map do |cell, index|
        other_cell = other.cells[index]
        Cell.new(
          cell.count - other_cell.count,
          mask_key(cell.key_sum - other_cell.key_sum),
          mask_checksum(cell.key_checksum - other_cell.key_checksum)
        )
      end)
      result
    end
    alias_method :-, :difference

    def recover(other)
      difference(other).decode
    end

    def decode
      working = @cells.map(&:dup)
      queue = []
      left_only = []
      right_only = []

      working.each_with_index do |cell, index|
        queue << index if cell.count.abs == 1
      end

      until queue.empty?
        index = queue.shift
        cell = working[index]
        sign = cell.count
        next unless sign.abs == 1

        candidate = sign == 1 ? cell.key_sum : mask_key(-cell.key_sum)
        digest = digest_for(candidate)
        checksum = checksum_for(candidate, digest)
        expected_key_sum = sign == 1 ? candidate : mask_key(-candidate)
        expected_checksum = sign == 1 ? checksum : mask_checksum(-checksum)

        next unless cell.key_sum == expected_key_sum &&
                    cell.key_checksum == expected_checksum &&
                    positions_for(candidate, digest).include?(index)

        (sign == 1 ? left_only : right_only) << candidate

        positions_for(candidate, digest).each do |position|
          neighbor = working[position]
          neighbor.count -= sign
          neighbor.key_sum = mask_key(neighbor.key_sum - sign * candidate)
          neighbor.key_checksum = mask_checksum(neighbor.key_checksum - sign * checksum)
          queue << position if neighbor.count.abs == 1
        end
      end

      residual = working.each_with_index.each_with_object([]) do |(cell, index), remaining|
        next if cell.count == 0 && cell.key_sum == 0 && cell.key_checksum == 0

        remaining << ResidualCell.new(
          index,
          cell.count,
          cell.key_sum,
          cell.key_checksum
        )
      end

      DecodeResult.new(
        residual.empty? ? :complete : :incomplete,
        left_only.sort.freeze,
        right_only.sort.freeze,
        residual.freeze
      )
    end

    def compatible?(other)
      other.is_a?(self.class) && parameters == other.parameters
    end

    def parameters
      {
        table_size: table_size,
        hash_count: hash_count,
        key_bytes: key_bytes,
        seed: seed,
        digest_id: digest_id
      }
    end

    def positions_for(id, digest = digest_for(id))
      validate_id!(id)
      base = digest.byteslice(0, 8).unpack1("Q>")
      step_hash = digest.byteslice(8, 8).unpack1("Q>")
      first = base % table_size

      return [first] if table_size == 1

      step = (step_hash % (table_size - 1)) + 1
      step += 1 until step.gcd(table_size) == 1

      Array.new(hash_count) do |i|
        (first + (i * step)) % table_size
      end
    end

    def to_h
      {
        "format" => SERIALIZATION_FORMAT,
        "version" => SERIALIZATION_VERSION,
        "digest" => digest_id,
        "table_size" => table_size,
        "hash_count" => hash_count,
        "key_bytes" => key_bytes,
        "seed" => seed,
        "cells" => @cells.map { |cell| [cell.count, cell.key_sum, cell.key_checksum] }
      }
    end

    def to_json(*args)
      JSON.generate(to_h, *args)
    end

    protected

    attr_reader :cells, :key_modulus, :checksum_modulus

    private

    def validate_id!(id)
      unless id.is_a?(Integer) && !id.negative? && id < key_modulus
        raise ArgumentError, "id must be an unsigned #{key_bytes}-byte integer"
      end
    end

    def ensure_locally_constructed!
      return unless @seen.nil?

      raise Error, "cannot insert into a received or derived IBLT summary"
    end

    def ensure_compatible!(other)
      return if compatible?(other)

      raise ArgumentError, "cannot combine IBLT summaries with different parameters"
    end

    def digest_for(id)
      validate_id!(id)
      Digest::SHA256.digest(digest_input(id))
    end

    def checksum_for(id, digest = digest_for(id))
      digest.byteslice(16, 8).unpack1("Q>") & (checksum_modulus - 1)
    end

    def digest_input(id)
      header = [1, key_bytes, table_size, hash_count, seed].pack("CCNNQ>")
      header.dup.force_encoding(Encoding::BINARY) << integer_to_bytes(id, key_bytes)
    end

    def integer_to_bytes(value, bytes)
      if bytes <= 8
        return [value].pack("Q>").byteslice(-bytes, bytes)
      end

      digits = Array.new(bytes) do
        digit = value & 0xff
        value >>= 8
        digit
      end
      digits.reverse.pack("C*")
    end

    def mask_key(value)
      value % key_modulus
    end

    def mask_checksum(value)
      value % checksum_modulus
    end

    def validate_positive_integer(value, name)
      value = validate_integer(value, name)
      unless value.positive?
        raise ArgumentError, "#{name} must be greater than zero"
      end
      value
    end

    def validate_integer(value, name)
      unless value.is_a?(Integer)
        raise ArgumentError, "#{name} must be an integer"
      end
      value
    end
  end
end
