=begin rdoc
    Exact cover solver based on Knuth's Algorithm X over a sparse
    "dancing links" matrix.

    The matrix is submitted as candidate rows. Every primary column must be
    covered by exactly one selected row, while secondary columns are
    optional: they may be left uncovered, but no two selected rows may share
    one ("can be unused, but never repeated").

    The search advances with reversible sparse cover/uncover operations; the
    matrix is mutated in place and restored on backtracking, never copied
    per level. Solutions are enumerated lazily through a session object, so
    a caller may stop after the first few solutions, close the session, and
    enumerate again later from a clean state.

    Following Algorithm X, a row enters a solution only to cover a primary
    column, so every selected row covers at least one primary column.

      cover = Algorithms::ExactCover.new(4, secondary_size: 2)
      cover.add_row(:r1, [0, 4])
      cover.add_row(:r2, [1, 3])
      cover.add_row(:r3, [0, 2])
      cover.add_row(:r4, [1, 3, 5])
      cover.solutions.each { |row_ids| p row_ids }

    Add all rows before enumerating. Only one session should be active at a
    time, since sessions drive the shared sparse matrix.
=end
module Algorithms
  class ExactCover
    # A single cell of the sparse matrix.
    class Node
      attr_accessor :left, :right, :up, :down, :column, :row
    end

    # A column header. Primary columns sit on the root header list and are
    # branching candidates; secondary columns stand alone and only enforce
    # the at-most-once constraint.
    class Column < Node
      attr_accessor :size, :index

      def initialize(index)
        @index = index
        @size = 0
        @left = @right = @up = @down = self
      end
    end

    # A candidate row: the caller-supplied id plus its cells.
    class Row
      attr_reader :id, :nodes

      def initialize(id)
        @id = id
        @nodes = []
      end
    end

    attr_reader :primary_size, :secondary_size

    # Columns 0...primary_size are primary (must be covered exactly once),
    # columns primary_size...primary_size+secondary_size are secondary
    # (covered at most once).
    def initialize(primary_size, secondary_size: 0)
      raise ArgumentError, "primary_size must be non-negative" if primary_size < 0
      raise ArgumentError, "secondary_size must be non-negative" if secondary_size < 0
      @primary_size = primary_size
      @secondary_size = secondary_size
      @root = Column.new(-1)
      @columns = Array.new(primary_size + secondary_size) { |i| Column.new(i) }
      @columns.each_with_index do |column, i|
        next if i >= primary_size
        column.left = @root.left
        column.right = @root
        @root.left.right = column
        @root.left = column
      end
      @rows = []
    end

    # Submits a candidate row covering the given column indices. Returns
    # self so calls can be chained. The row_id is reported back verbatim in
    # solutions.
    def add_row(row_id, columns)
      indices = columns.to_a.uniq
      indices.each do |i|
        unless i.is_a?(Integer) && i >= 0 && i < @columns.size
          raise ArgumentError, "column index out of range: #{i.inspect}"
        end
      end
      row = Row.new(row_id)
      first = nil
      indices.each do |i|
        column = @columns[i]
        node = Node.new
        node.column = column
        node.row = row
        node.down = column
        node.up = column.up
        column.up.down = node
        column.up = node
        column.size += 1
        if first.nil?
          first = node
          node.left = node.right = node
        else
          node.left = first.left
          node.right = first
          first.left.right = node
          first.left = node
        end
        row.nodes << node
      end
      @rows << row
      self
    end

    # Returns a fresh, lazily-evaluated session enumerating every solution
    # as an array of row ids. Enumeration order is deterministic.
    def solutions
      Session.new(self)
    end

    # Yields each solution (an array of row ids) to the block, or returns a
    # session enumerator when no block is given.
    def each_solution(&block)
      session = solutions
      return session unless block_given?
      session.each(&block)
      self
    end

    private

    # Unlinks a column and every row that crosses it. Fully reversed by
    # uncover, so the matrix is restored exactly on backtracking.
    def cover(column)
      column.right.left = column.left
      column.left.right = column.right
      i = column.down
      until i.equal?(column)
        j = i.right
        until j.equal?(i)
          j.down.up = j.up
          j.up.down = j.down
          j.column.size -= 1
          j = j.right
        end
        i = i.down
      end
    end

    def uncover(column)
      i = column.up
      until i.equal?(column)
        j = i.left
        until j.equal?(i)
          j.column.size += 1
          j.down.up = j
          j.up.down = j
          j = j.left
        end
        i = i.up
      end
      column.right.left = column
      column.left.right = column
    end

    def cover_row(row)
      row.nodes.each { |node| cover(node.column) }
    end

    def uncover_row(row)
      row.nodes.reverse_each { |node| uncover(node.column) }
    end

    def primary_covered?
      @root.right.equal?(@root)
    end

    # Deterministic branching: the uncovered primary column with the fewest
    # candidate rows, ties broken by column order.
    def choose_column
      best = nil
      column = @root.right
      until column.equal?(@root)
        best = column if best.nil? || column.size < best.size
        column = column.right
      end
      best
    end

    # Lazily enumerates solutions. The search runs on an explicit stack of
    # frames instead of recursion, and the partial solution path stays
    # covered between solutions; reset/close uncovers whatever is left, so
    # the matrix always returns to its initial state and a later session
    # reproduces the same solutions.
    class Session
      include Enumerable

      def initialize(problem)
        @problem = problem
        @frames = []
        @path = []
        @started = false
        @pending = false
      end

      def each
        return enum_for(:each) unless block_given?
        reset
        begin
          loop do
            solution = next_solution
            break if solution.nil?
            yield solution
          end
        ensure
          reset
        end
        self
      end

      # Returns the next solution as an array of row ids, or nil when the
      # search space is exhausted.
      def next_solution
        if @pending
          @pending = false
          row = @path.pop
          @problem.send(:uncover_row, row) if row
        end
        loop do
          unless @started
            @started = true
            if @problem.send(:primary_covered?)
              @pending = true
              return []
            end
            column = @problem.send(:choose_column)
            @frames.push([column, column.down])
            next
          end
          return nil if @frames.empty?
          frame = @frames.last
          node = frame[1]
          if node.equal?(frame[0])
            @frames.pop
            @problem.send(:uncover_row, @path.pop) unless @frames.empty?
            next
          end
          frame[1] = node.down
          @problem.send(:cover_row, node.row)
          @path.push(node.row)
          if @problem.send(:primary_covered?)
            @pending = true
            return @path.map(&:id)
          end
          column = @problem.send(:choose_column)
          @frames.push([column, column.down])
        end
      end

      # Restores the matrix to its initial state and rewinds the search, so
      # the session (or a fresh one) enumerates the same solutions again.
      def reset
        @problem.send(:uncover_row, @path.pop) until @path.empty?
        @frames.clear
        @started = false
        @pending = false
        self
      end
      alias close reset
    end
  end
end
