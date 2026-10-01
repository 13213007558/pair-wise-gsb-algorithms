=begin rdoc

    An R-tree stores two-dimensional rectangles and supports efficient
    intersection and containment queries. Rectangles are represented as
    [xmin, ymin, xmax, ymax]. Touching a boundary counts as intersection.

    tree = Containers::RTree.new(4)
    tree.insert(1, [0, 0, 2, 2])
    tree.insert(2, [5, 5, 7, 7])
    tree.search([1, 1, 6, 6]) # => [1, 2]

=end

class Containers::RTree
  Entry = Struct.new(:id, :rectangle)
  Node = Struct.new(:leaf, :entries) do
    def bounding
      return nil if entries.empty?

      entries.map { |entry| entry.is_a?(Node) ? entry.bounding : entry.rectangle }.reduce do |combined, rectangle|
        [
          [combined[0], rectangle[0]].min,
          [combined[1], rectangle[1]].min,
          [combined[2], rectangle[2]].max,
          [combined[3], rectangle[3]].max
        ]
      end
    end
  end

  attr_reader :size, :capacity, :root

  def initialize(capacity = 8)
    raise ArgumentError, "capacity must be at least 2" unless capacity.is_a?(Integer) && capacity >= 2

    @capacity = capacity
    @minimum_capacity = (capacity / 2.0).ceil
    @root = Node.new(true, [])
    @entries = {}
    @size = 0
  end

  def insert(id, rectangle)
    rectangle = normalize_rectangle(rectangle)
    delete(id) if @entries.key?(id)

    entry = Entry.new(id, rectangle)
    @entries[id] = rectangle
    insert_entry(entry)
    @size = @entries.size
    self
  end
  alias []= insert
  alias update insert

  def delete(id)
    rectangle = @entries[id]
    return nil unless rectangle

    _removed, orphan_entries = remove_from_node(@root, id, rectangle)
    @entries.delete(id)
    normalize_root
    orphan_entries.each { |orphan| insert_entry(orphan) }
    @size = @entries.size
    rectangle
  end
  alias remove delete

  def rectangle(id)
    rectangle = @entries[id]
    rectangle && rectangle.dup
  end
  alias [] rectangle

  def empty?
    @entries.empty?
  end

  def search(rectangle, mode = :intersect)
    rectangle = normalize_rectangle(rectangle)
    results = []
    collect(@root, rectangle, mode, results)
    results
  end
  alias query search

  def intersecting(rectangle)
    search(rectangle, :intersect)
  end
  alias find intersecting
  alias intersects intersecting
  alias find_intersecting intersecting

  def contained(rectangle)
    search(rectangle, :contain)
  end
  alias contains contained
  alias contained_in contained
  alias find_contained contained

  def containing(rectangle)
    search(rectangle, :containing)
  end
  alias find_containing containing

  def to_h
    @entries.transform_values(&:dup)
  end

  def valid?
    validate_node(@root, true)
  end

  private

  def normalize_rectangle(rectangle)
    unless rectangle.is_a?(Array) && rectangle.size == 4 && rectangle.all? { |value| value.is_a?(Numeric) }
      raise ArgumentError, "rectangle must be an array of four numeric values"
    end

    rectangle = rectangle.dup
    unless rectangle[0] <= rectangle[2] && rectangle[1] <= rectangle[3]
      raise ArgumentError, "rectangle minima must be less than or equal to maxima"
    end

    rectangle
  end

  def insert_entry(entry)
    result = insert_into_node(@root, entry)
    @root = Node.new(false, result) if result.is_a?(Array)
  end

  def insert_into_node(node, entry)
    if node.leaf
      node.entries << entry
      return node unless node.entries.size > @capacity

      split_node(node)
    else
      child = choose_child(node, entry.rectangle)
      result = insert_into_node(child, entry)

      if result.is_a?(Array)
        index = node.entries.index(child)
        node.entries.delete_at(index)
        node.entries.insert(index, *result)
        return split_node(node) if node.entries.size > @capacity
      end

      node
    end
  end

  def choose_child(node, rectangle)
    node.entries.each_with_index.min_by do |child, index|
      bounding = child.bounding
      [
        rectangle_area(union(bounding, rectangle)) - rectangle_area(bounding),
        rectangle_area(bounding),
        index
      ]
    end.first
  end

  def split_node(node)
    entries = node.entries
    first, second = pick_seeds(entries)
    groups = [[first], [second]]
    remaining = entries.dup
    remaining.delete(first)
    remaining.delete(second)

    until remaining.empty?
      forced_index = forced_group_index(groups, remaining.size)
      entry, group_index = forced_index ? [pick_forced_entry(remaining, groups, forced_index), forced_index] : pick_next_entry(remaining, groups)
      groups[group_index] << entry
      remaining.delete(entry)
    end

    groups.map { |group| Node.new(node.leaf, group) }
  end

  def pick_seeds(entries)
    entries.combination(2).max_by do |first, second|
      first_rectangle = rectangle_for(first)
      second_rectangle = rectangle_for(second)
      rectangle_area(union(first_rectangle, second_rectangle)) - rectangle_area(first_rectangle) - rectangle_area(second_rectangle)
    end
  end

  def pick_next_entry(remaining, groups)
    remaining.map do |entry|
      enlargements = groups.map { |group| enlargement(group, entry) }
      preferred_group = enlargements[0] <= enlargements[1] ? 0 : 1
      [entry, (enlargements[0] - enlargements[1]).abs, preferred_group]
    end.max_by { |_entry, difference, group| [difference, group] }.values_at(0, 2)
  end

  def pick_forced_entry(remaining, groups, group_index)
    remaining.min_by { |entry| enlargement(groups[group_index], entry) }
  end

  def forced_group_index(groups, remaining_size)
    if groups[0].size + remaining_size == @minimum_capacity
      0
    elsif groups[1].size + remaining_size == @minimum_capacity
      1
    end
  end

  def enlargement(group, entry)
    bounding = bounding_for(group)
    rectangle_area(union(bounding, rectangle_for(entry))) - rectangle_area(bounding)
  end

  def remove_from_node(node, id, rectangle)
    if node.leaf
      index = node.entries.index { |entry| entry.id == id && entry.rectangle == rectangle }
      return [false, []] unless index

      node.entries.delete_at(index)
      return [true, []]
    end

    node.entries.each do |child|
      next unless contains?(child.bounding, rectangle)

      removed, orphans = remove_from_node(child, id, rectangle)
      next unless removed

      if child.entries.size < @minimum_capacity
        node.entries.delete(child)
        orphans.concat(all_entries(child))
      end

      return [true, orphans]
    end

    [false, []]
  end

  def normalize_root
    until @root.leaf || @root.entries.size != 1
      @root = @root.entries.first
    end

    @root = Node.new(true, []) if !@root.leaf && @root.entries.empty?
  end

  def all_entries(node)
    return node.entries.dup if node.leaf

    node.entries.flat_map { |child| all_entries(child) }
  end

  def collect(node, query, mode, results)
    if node.leaf
      node.entries.each do |entry|
        results << entry.id if matches?(entry.rectangle, query, mode)
      end
    elsif intersects?(node.bounding, query)
      node.entries.each { |child| collect(child, query, mode, results) }
    end
  end

  def matches?(rectangle, query, mode)
    case mode
    when :intersect, :intersection, :intersects
      intersects?(rectangle, query)
    when :contain, :contains, :contained
      contains?(query, rectangle)
    when :containing
      contains?(rectangle, query)
    else
      raise ArgumentError, "unknown query mode: #{mode.inspect}"
    end
  end

  def intersects?(first, second)
    !(first[2] < second[0] || second[2] < first[0] ||
      first[3] < second[1] || second[3] < first[1])
  end

  def contains?(outer, inner)
    outer[0] <= inner[0] && outer[1] <= inner[1] &&
      outer[2] >= inner[2] && outer[3] >= inner[3]
  end

  def union(first, second)
    [
      [first[0], second[0]].min,
      [first[1], second[1]].min,
      [first[2], second[2]].max,
      [first[3], second[3]].max
    ]
  end

  def rectangle_area(rectangle)
    width = rectangle[2] - rectangle[0]
    height = rectangle[3] - rectangle[1]
    width * height
  end

  def rectangle_for(entry)
    entry.is_a?(Node) ? entry.bounding : entry.rectangle
  end

  def bounding_for(group)
    group.map { |entry| rectangle_for(entry) }.reduce { |combined, rectangle| union(combined, rectangle) }
  end

  def validate_node(node, root_node)
    return false unless node.entries.size <= @capacity
    return false if !root_node && node.entries.size < @minimum_capacity
    return false if node.entries.empty? != node.bounding.nil?

    unless node.entries.empty?
      expected = node.entries.map { |entry| rectangle_for(entry) }.reduce { |combined, rectangle| union(combined, rectangle) }
      return false unless node.bounding == expected
    end

    if node.leaf
      node.entries.all? do |entry|
        @entries.key?(entry.id) && @entries[entry.id] == entry.rectangle
      end
    else
      node.entries.all? { |child| validate_node(child, false) }
    end
  end
end
