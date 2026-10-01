begin
  require 'objspace'
rescue LoadError
end

require 'rbconfig'

module Containers
  # Static index for an integer array supporting half-open range order-statistic queries.
  class StaticRangeIndex
    class EmptyRangeError < ArgumentError; end
    class InvalidRangeError < ArgumentError; end
    class KOutOfRangeError < IndexError; end

    def initialize(values)
      unless values.is_a?(Array) && values.all? { |value| value.is_a?(Integer) }
        raise ArgumentError, 'values must be an array of integers'
      end

      @size = values.size
      @coordinates = values.uniq.sort
      positions = {}
      @coordinates.each_with_index { |value, index| positions[value] = index }

      @left_child = [0]
      @right_child = [0]
      @node_count = [0]
      @roots = [0]

      values.each do |value|
        @roots << insert(@roots.last, 0, @coordinates.size - 1, positions.fetch(value))
      end
    end

    def size
      @size
    end

    def kth(start_index, end_index, k)
      validate_range(start_index, end_index)
      raise EmptyRangeError, 'cannot take an order statistic from an empty range' if start_index == end_index
      unless k.is_a?(Integer) && k >= 1 && k <= end_index - start_index
        raise KOutOfRangeError, "k must be between 1 and #{end_index - start_index}"
      end

      left_root = @roots[start_index]
      right_root = @roots[end_index]
      low = 0
      high = @coordinates.size - 1

      while low < high
        middle = (low + high) / 2
        left_frequency = @node_count[@left_child[right_root]] - @node_count[@left_child[left_root]]

        if k <= left_frequency
          right_root = @left_child[right_root]
          left_root = @left_child[left_root]
          high = middle
        else
          k -= left_frequency
          right_root = @right_child[right_root]
          left_root = @right_child[left_root]
          low = middle + 1
        end
      end

      @coordinates[low]
    end

    def count(value, start_index, end_index)
      validate_integer(value, 'value')
      validate_range(start_index, end_index)
      position = @coordinates.bsearch_index { |coordinate| coordinate >= value }
      return 0 if position.nil? || @coordinates[position] != value

      leaf_count(@roots[end_index], position) - leaf_count(@roots[start_index], position)
    end

    def count_less(value, start_index, end_index)
      validate_integer(value, 'value')
      validate_range(start_index, end_index)
      rank = @coordinates.bsearch_index { |coordinate| coordinate >= value }
      rank = @coordinates.size if rank.nil?

      prefix_count(@roots[end_index], rank) - prefix_count(@roots[start_index], rank)
    end

    def index_nodes
      @left_child.size - 1
    end

    def index_bytes
      arrays = [@roots, @coordinates, @left_child, @right_child, @node_count]
      bytes = ObjectSpace.respond_to?(:memsize_of) ? ObjectSpace.memsize_of(self) : 0
      bytes + arrays.sum { |array| measured_bytes(array) }
    end

    private

    def insert(previous, low, high, position)
      node = @left_child.size
      @left_child << @left_child[previous]
      @right_child << @right_child[previous]
      @node_count << @node_count[previous] + 1

      unless low == high
        middle = (low + high) / 2
        if position <= middle
          @left_child[node] = insert(@left_child[previous], low, middle, position)
        else
          @right_child[node] = insert(@right_child[previous], middle + 1, high, position)
        end
      end

      node
    end

    def leaf_count(root, position)
      low = 0
      high = @coordinates.size - 1

      while root != 0 && low < high
        middle = (low + high) / 2
        if position <= middle
          root = @left_child[root]
          high = middle
        else
          root = @right_child[root]
          low = middle + 1
        end
      end

      root.zero? ? 0 : @node_count[root]
    end

    def prefix_count(root, exclusive_position)
      return 0 if root == 0 || exclusive_position <= 0 || @coordinates.empty?
      return @node_count[root] if exclusive_position >= @coordinates.size

      low = 0
      high = @coordinates.size - 1
      result = 0

      while low < high && root != 0
        middle = (low + high) / 2
        if exclusive_position <= middle
          root = @left_child[root]
          high = middle
        else
          result += @node_count[@left_child[root]]
          root = @right_child[root]
          low = middle + 1
        end
      end

      result
    end

    def validate_range(start_index, end_index)
      validate_integer(start_index, 'start index')
      validate_integer(end_index, 'end index')
      unless start_index >= 0 && end_index <= @size && start_index <= end_index
        raise InvalidRangeError, "range must be [start, end) inside [0, #{@size})"
      end
    end

    def validate_integer(value, name)
      raise ArgumentError, "#{name} must be an integer" unless value.is_a?(Integer)
    end

    def measured_bytes(array)
      return ObjectSpace.memsize_of(array) if ObjectSpace.respond_to?(:memsize_of)

      RbConfig::SIZEOF['void*'] * array.size
    end
  end
end
