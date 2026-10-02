module Algorithms
  # Sparse exact cover enumerator implemented with Dancing Links.
  #
  # Primary columns must be covered exactly once by the selected rows.
  # Secondary columns are optional, but a solution cannot contain two rows
  # covering the same secondary column. Search mutates reversible links in
  # place and restores the complete sparse matrix when enumeration stops.
  class SparseExactCover
    include Enumerable

    class << self
      alias_method :enumerate, :new
    end

    # Creates an exact cover problem from candidate rows.
    #
    # Rows may be supplied as a Hash of original row ID to columns, or as an
    # Array of +[id, columns]+ pairs. Columns may be any Array or Set.
    #
    #   cover = Algorithms::SparseExactCover.new(
    #     { a: [1, :x], b: [2, :x], c: [1], d: [2] },
    #     primary_columns: [1, 2],
    #     secondary_columns: [:x]
    #   )
    #   cover.to_a # => [[:a, :d], [:b, :c], [:c, :d]]
    def initialize(*args)
      options_hash = args.length == 1 && args.first.is_a?(Hash) ? args.first : args.last
      if options_hash.is_a?(Hash) &&
          (options_hash.key?(:primary) || options_hash.key?(:primary_columns) ||
           options_hash.key?(:secondary) || options_hash.key?(:secondary_columns) ||
           options_hash.key?(:rows) || options_hash.key?(:candidates))
        keyword_options = args.pop
      else
        keyword_options = {}
      end
      raise ArgumentError, "wrong number of arguments" if args.length > 3

      positional_rows, positional_primary_columns,
        positional_secondary_columns = args
      options = symbolize_options(keyword_options)
      candidate_option = options[:rows] || options[:candidates]
      supplied_rows = [positional_rows, candidate_option].compact
      if supplied_rows.empty?
        raise ArgumentError, "rows are required"
      elsif supplied_rows.length > 1
        raise ArgumentError, "rows were supplied more than once"
      end

      primary_option = options[:primary] || options[:primary_columns] ||
        positional_primary_columns
      secondary_option = options[:secondary] || options[:secondary_columns] ||
        positional_secondary_columns

      @active = false
      @candidate_rows = []
      @seen_row_ids = {}

      read_rows(supplied_rows.first)
      build_columns(primary_option, secondary_option)
      build_matrix
    end

    # Yields each solution as an Array of original row IDs. Returns an
    # Enumerator when called without a block. Stopping after only some
    # solutions restores all links, so a subsequent enumeration starts again
    # from the first solution.
    def each
      return SolutionEnumerator.new(self) unless block_given?
      raise ArgumentError, "an enumeration is already active" if @active

      begin
        start_search { |solution| yield solution }
      ensure
        restore_search
      end
    end
    alias_method :each_solution, :each

    def solutions
      to_a
    end

    attr_reader :active
    alias_method :active?, :active

    private

    def symbolize_options(options)
      return {} if options.nil?
      unless options.is_a?(Hash)
        raise ArgumentError, "options must be a Hash"
      end

      symbolized = {}
      options.each do |key, value|
        symbolized[key.to_sym] = value if key.respond_to?(:to_sym)
      end
      symbolized
    end

    def read_rows(rows)
      if rows.is_a?(Hash)
        rows.each { |id, columns| add_candidate_row(id, columns) }
      elsif rows.is_a?(Array)
        rows.each_with_index do |row, index|
          if row.is_a?(Hash)
            id = row.fetch(:id) { row.fetch(:row_id, index) }
            columns = row.fetch(:columns) { row.fetch(:cols) }
          elsif row.is_a?(Array) && row.length == 2
            id, columns = row
          else
            raise ArgumentError, "row #{index} must be [id, columns]"
          end
          add_candidate_row(id, columns)
        end
      else
        raise ArgumentError, "rows must be a Hash or an Array"
      end
    end

    def add_candidate_row(id, columns)
      unless columns.respond_to?(:each) && !columns.is_a?(Hash)
        raise ArgumentError, "columns for row #{id.inspect} must be a collection"
      end
      if @seen_row_ids.key?(id)
        raise ArgumentError, "duplicate row ID #{id.inspect}"
      end

      normalized_columns = []
      columns.each do |column|
        if normalized_columns.include?(column)
          raise ArgumentError, "column #{column.inspect} appears twice in row #{id.inspect}"
        end
        normalized_columns << column
      end

      @seen_row_ids[id] = true
      @candidate_rows << [id, normalized_columns]
    end

    def build_columns(primary_option, secondary_option)
      secondary_columns = normalize_columns(secondary_option, "secondary columns")
      secondary_set = {}
      secondary_columns.each { |column| secondary_set[column] = true }

      if primary_option.nil?
        @primary_columns = []
        @candidate_rows.each do |_, columns|
          columns.each do |column|
            next if secondary_set.key?(column) || @primary_columns.include?(column)
            @primary_columns << column
          end
        end
        @secondary_columns = secondary_columns
      else
        @primary_columns = normalize_columns(primary_option, "primary columns")
        @secondary_columns = secondary_columns
        primary_set = {}
        @primary_columns.each { |column| primary_set[column] = true }

        @candidate_rows.each do |id, columns|
          columns.each do |column|
            unless primary_set.key?(column) || secondary_set.key?(column)
              raise ArgumentError, "row #{id.inspect} contains undeclared column #{column.inspect}"
            end
          end
        end
      end

      @secondary_columns.each do |column|
        if @primary_columns.include?(column)
          raise ArgumentError, "column #{column.inspect} is both primary and secondary"
        end
      end
    end

    def normalize_columns(value, name)
      return [] if value.nil?
      unless value.respond_to?(:each) && !value.is_a?(Hash)
        value = [value]
      end

      columns = []
      value.each do |column|
        if columns.include?(column)
          raise ArgumentError, "#{name} contains #{column.inspect} more than once"
        end
        columns << column
      end
      columns
    end

    def build_matrix
      @column_index = {}
      @column_of = []
      @left = []
      @right = []
      @up = []
      @down = []
      @row_id = []
      @column_size = []
      @row_index = {}

      @left[0] = @right[0] = @up[0] = @down[0] = @column_of[0] = 0
      @column_size[0] = 0

      @primary_columns.each { |column| create_header(column, true) }
      @secondary_columns.each { |column| create_header(column, false) }

      @candidate_rows.each_with_index { |(id, columns), index|
        @row_index[id] = index
        add_matrix_row(id, columns)
      }
    end

    def create_header(column, primary)
      header = @left.length
      @column_index[column] = header
      @column_of[header] = header
      @up[header] = @down[header] = header
      @column_size[header] = 0

      if primary
        @left[header] = @left[0]
        @right[header] = 0
        @right[@left[0]] = header
        @left[0] = header
      else
        @left[header] = @right[header] = header
      end
      header
    end

    def add_matrix_row(id, columns)
      first = nil
      columns.each do |column|
        header = @column_index.fetch(column)
        node = @left.length
        @column_of[node] = header
        @row_id[node] = id
        @up[node] = @up[header]
        @down[node] = header
        @down[@up[header]] = node
        @up[header] = node
        @column_size[header] += 1

        if first.nil?
          @left[node] = @right[node] = node
          first = node
        else
          @left[node] = @left[first]
          @right[node] = first
          @right[@left[first]] = node
          @left[first] = node
        end
      end
    end

    def start_search
      @frame_stack = []
      @active = true
      search([]) { |solution| yield solution }
    ensure
      @active = false
    end

    def search(chosen)
      if @right[0] == 0
        yield chosen.sort_by { |id| @row_index[id] }
        return
      end

      column = choose_column
      return if @column_size[column].zero?

      cover(column)
      node = @down[column]
      while node != column
        chosen << @row_id[node]
        cover_selected_row(node)
        @frame_stack << [column, node]
        search(chosen) { |solution| yield solution }
        @frame_stack.pop
        uncover_selected_row(node)
        chosen.pop
        node = @down[node]
      end
      uncover(column)
    end

    def choose_column
      column = @right[0]
      candidate = @right[column]
      while candidate != 0
        column = candidate if @column_size[candidate] < @column_size[column]
        candidate = @right[candidate]
      end
      column
    end

    def cover_selected_row(node)
      sibling = @right[node]
      while sibling != node
        cover(@column_of[sibling])
        sibling = @right[sibling]
      end
    end

    def restore_search
      @active = false
      return unless @frame_stack
      while (column, node = @frame_stack.pop) && column
        uncover_selected_row(node)
        uncover(column)
      end
    end

    def force_deactivate
      @active = false
    end

    def uncover_selected_row(node)
      sibling = @left[node]
      while sibling != node
        uncover(@column_of[sibling])
        sibling = @left[sibling]
      end
    end

    def cover(column)
      row = @down[column]
      while row != column
        node = @right[row]
        while node != row
          @up[@down[node]] = @up[node]
          @down[@up[node]] = @down[node]
          @column_size[@column_of[node]] -= 1
          node = @right[node]
        end
        row = @down[row]
      end

      @right[@left[column]] = @right[column]
      @left[@right[column]] = @left[column]
    end

    def uncover(column)
      @right[@left[column]] = column
      @left[@right[column]] = column

      row = @up[column]
      while row != column
        node = @left[row]
        while node != row
          @column_size[@column_of[node]] += 1
          @up[@down[node]] = node
          @down[@up[node]] = node
          node = @left[node]
        end
        row = @up[row]
      end
    end
  end

  class SparseExactCover::SolutionEnumerator
    include Enumerable

    class StopEnumeration < StandardError; end

    def initialize(cover)
      @cover = cover
      @closed = false
      @fiber = nil
    end

    def initialize_copy(_other)
      @closed = false
      @fiber = nil
    end

    def each
      return dup unless block_given?
      raise StopIteration, "iteration has been closed" if closed?

      begin
        yield fiber.resume while fiber.alive?
      ensure
        finish
      end
    end

    def peek
      @next_value ||= __send__(:next)
    end

    def next
      @next_value = nil
      raise StopIteration, "iteration has finished" if closed? || (@fiber && !@fiber.alive?)
      fiber.resume
    end

    def rewind
      close
      @fiber = nil
      self
    end

    def close
      return self if closed?
      finish
    end

    def closed?
      @closed
    end

    private

    def fiber
      @fiber ||= Fiber.new do
        begin
          @cover.send(:start_search) do |solution|
            command = Fiber.yield(solution)
            raise StopEnumeration if command == :stop
          end
        rescue StopEnumeration
          nil
        end
      end
    end

    def finish
      @cover.send(:restore_search) if @fiber && @fiber.alive?
      @fiber.resume(:stop) if @fiber && @fiber.alive?
      @cover.send(:force_deactivate)
      @closed = true
      self
    end
  end

  ExactCover = SparseExactCover
end
