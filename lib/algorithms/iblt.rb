module Algorithms
  # Invertible Bloom Lookup Table for set reconciliation of fixed-width unsigned integers.
  class IBLT
    MASK64 = 0xffffffffffffffff
    VALID_BIT_WIDTHS = [8, 16, 32, 64].freeze

    Cell = Struct.new(:count, :key_sum, :key_checksum) do
      def empty?
        count.zero? && key_sum.zero? && key_checksum.zero?
      end

      def to_h
        {:count => count, :key_sum => key_sum, :key_checksum => key_checksum}
      end
    end

    class ParameterMismatch < ArgumentError; end
    class InvalidID < ArgumentError; end

    class Residual
      attr_reader :cells, :parameters

      def initialize(cells, parameters)
        @parameters = parameters.dup.freeze
        @cells = cells.map do |cell|
          cell.dup.freeze
        end.freeze
      end

      def empty?
        cells.all? { |cell| cell.empty? }
      end

      def active_cells
        cells.reject { |cell| cell.empty? }
      end

      def each_active_cell(&block)
        active_cells.each(&block)
      end

      def to_h
        {
          :parameters => parameters.dup,
          :cells => cells.map { |cell| cell.dup.to_h }
        }
      end
    end

    class RecoveryResult
      attr_reader :left_only, :right_only, :residual

      def initialize(status, left_only, right_only, residual)
        @status = status
        @left_only = left_only.sort.freeze
        @right_only = right_only.sort.freeze
        @residual = residual
      end

      def status
        @status
      end

      def complete?
        status == :complete
      end

      def no_difference?
        status == :no_difference
      end

      def incomplete?
        status == :partial || status == :failed
      end

      def recovered_any?
        !left_only.empty? || !right_only.empty?
      end

      def to_h
        {
          :status => status,
          :left_only => left_only.dup,
          :right_only => right_only.dup,
          :residual => residual.to_h
        }
      end
    end

    def initialize(buckets, hash_count, seed = 0, bit_width = 64)
      @buckets = validate_positive_integer(buckets, :buckets)
      @hash_count = validate_positive_integer(hash_count, :hash_count)
      @seed = normalize_unsigned_integer(seed, 64, :seed)
      @bit_width = validate_bit_width(bit_width)
      @id_mask = 2 ** @bit_width - 1
      @cells = Array.new(@buckets) { Cell.new(0, 0, 0) }
      @inserted = {}
    end

    attr_reader :buckets, :hash_count, :seed, :bit_width

    def parameters
      {
        :buckets => buckets,
        :hash_count => hash_count,
        :seed => seed,
        :bit_width => bit_width
      }.freeze
    end

    def compatible_parameters?(other)
      other.is_a?(IBLT) && other.parameters == parameters
    end

    def cells
      @cells.map { |cell| cell.dup }
    end

    def indexes_for(id)
      validate_id(id)
      indexes = Set.new
      base = mix64(id ^ seed)
      hash_count.times do |round|
        indexes << mix64(base ^ round) % buckets
      end
      indexes.to_a
    end

    # Inserts an ID using set semantics. Repeated insertion of the same ID is ignored.
    def insert(id)
      validate_id(id)
      return false if @inserted.key?(id)

      indexes_for(id).each do |index|
        cell = @cells[index]
        cell.count += 1
        cell.key_sum = mask_id(cell.key_sum ^ id)
        cell.key_checksum = mask64(cell.key_checksum ^ checksum_for(id))
      end
      @inserted[id] = true
      true
    end
    alias_method :add, :insert
    alias_method :<<, :insert

    def inserted?(id)
      validate_id(id)
      @inserted.key?(id)
    end

    def insert_all(ids)
      ids.each { |id| insert(id) }
      self
    end

    def difference(other)
      compatible!(other)
      result = self.class.new(buckets, hash_count, seed, bit_width)
      other_cells = other.cells
      @cells.each_with_index do |cell, index|
        result_cell = result.instance_variable_get(:@cells)[index]
        result_cell.count = cell.count - other_cells[index].count
        result_cell.key_sum = mask_id(cell.key_sum ^ other_cells[index].key_sum)
        result_cell.key_checksum = mask64(cell.key_checksum ^ other_cells[index].key_checksum)
      end
      result
    end
    alias_method :-, :difference

    def recover
      working = cells
      left_only = []
      right_only = []

      if working.all? { |cell| cell.empty? }
        return RecoveryResult.new(:no_difference, left_only, right_only,
                                  Residual.new(working, parameters))
      end

      loop do
        removed = false
        candidates = []
        working.each_with_index do |cell, index|
          next unless cell.count.abs == 1
          id = cell.key_sum
          if valid_id?(id) && cell.key_checksum == checksum_for(id)
            indexes = indexes_for(id)
            candidates << [cell, index, id, indexes] if indexes.include?(index)
          end
        end
        candidates.each do |cell, index, id, indexes|
          next unless cell.count.abs == 1
          next unless cell.key_sum == id && cell.key_checksum == checksum_for(id)
          next unless indexes.include?(index)

          side = cell.count > 0 ? left_only : right_only
          side << id unless side.include?(id)
          direction = cell.count
          indexes.each do |index|
            remove_from_cell(working[index], id, direction)
          end
          removed = true
        end
        break unless removed
      end

      status = if working.all? { |cell| cell.empty? }
                 :complete
               elsif left_only.any? || right_only.any?
                 :partial
               else
                 :failed
               end
      RecoveryResult.new(status, left_only, right_only, Residual.new(working, parameters))
    end

    def to_h
      {
        :parameters => parameters.dup,
        :cells => @cells.map { |cell| cell.dup.to_h }
      }
    end

    def self.from_h(data)
      parameters = data.fetch(:parameters)
      digest = new(parameters.fetch(:buckets), parameters.fetch(:hash_count),
                   parameters.fetch(:seed, 0), parameters.fetch(:bit_width, 64))
      cells = data.fetch(:cells)
      unless cells.is_a?(Array) && cells.length == digest.buckets
        raise ArgumentError, "cells must contain #{digest.buckets} entries"
      end

      cells.each_with_index do |cell_data, index|
        cell = digest.instance_variable_get(:@cells)[index]
        count = cell_data.fetch(:count)
        unless count.is_a?(Integer)
          raise ArgumentError, "count must be an integer"
        end
        cell.count = count
        cell.key_sum = digest.send(:normalize_serialized_id, cell_data.fetch(:key_sum))
        cell.key_checksum = digest.send(:normalize_serialized_checksum,
                                       cell_data.fetch(:key_checksum))
      end
      digest
    end

    def marshal_dump
      to_h
    end

    def marshal_load(data)
      loaded = self.class.from_h(data)
      parameters = loaded.parameters
      initialize(parameters[:buckets], parameters[:hash_count], parameters[:seed],
                 parameters[:bit_width])
      @cells.replace(loaded.cells)
    end

    private

    def remove_from_cell(cell, id, signed_count)
      cell.count -= signed_count
      cell.key_sum = mask_id(cell.key_sum ^ id)
      cell.key_checksum = mask64(cell.key_checksum ^ checksum_for(id))
    end

    def compatible!(other)
      return if compatible_parameters?(other)
      raise ParameterMismatch,
            "cannot combine IBLTs with parameters #{parameters.inspect} and " \
            "#{other.respond_to?(:parameters) ? other.parameters.inspect : other.inspect}"
    end

    def checksum_for(id)
      mix64(id ^ seed ^ 0x9e3779b97f4a7c15)
    end

    def mix64(value)
      value = mask64(value)
      value = mask64((value ^ (value >> 30)) * 0xbf58476d1ce4e5b9)
      value = mask64((value ^ (value >> 27)) * 0x94d049bb133111eb)
      value ^ (value >> 31)
    end

    def mask64(value)
      value & MASK64
    end

    def mask_id(value)
      value & @id_mask
    end

    def valid_id?(id)
      id.is_a?(Integer) && id >= 0 && id <= @id_mask
    end

    def validate_id(id)
      return if valid_id?(id)
      raise InvalidID,
            "ID must be an unsigned #{bit_width}-bit integer (0..#{@id_mask})"
    end

    def validate_positive_integer(value, name)
      unless value.is_a?(Integer) && value > 0
        raise ArgumentError, "#{name} must be a positive integer"
      end
      value
    end

    def validate_bit_width(value)
      unless VALID_BIT_WIDTHS.include?(value)
        raise ArgumentError, "bit_width must be one of #{VALID_BIT_WIDTHS.inspect}"
      end
      value
    end

    def normalize_unsigned_integer(value, width, name)
      unless value.is_a?(Integer) && value >= 0 && value < 2 ** width
        raise ArgumentError, "#{name} must be an unsigned #{width}-bit integer"
      end
      value
    end

    def normalize_serialized_id(value)
      validate_id(value)
      value
    end

    def normalize_serialized_checksum(value)
      normalize_unsigned_integer(value, 64, :key_checksum)
    end

  end
end
