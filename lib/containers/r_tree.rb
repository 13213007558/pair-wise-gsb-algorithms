=begin rdoc
    An R-tree stores rectangles associated with IDs and supports spatial
    intersection and containment searches.

    Rectangles are represented as four-number arrays:

      [minimum_x, minimum_y, maximum_x, maximum_y]

    Point queries can be expressed with zero-width and zero-height rectangles.
    Rectangles whose edges or corners touch are considered intersecting. IDs
    are unique: inserting an existing ID replaces its old rectangle and leaves
    no stale entry in the tree.
=end

class Containers::RTree
  include Enumerable

  Entry = Struct.new(:id, :rectangle, :child)

  class Node
    attr_accessor :entries, :leaf

    def initialize(leaf = true)
      @entries = []
      @leaf = leaf
    end

    def leaf?
      @leaf
    end

    def bounding_box
      Containers::RTree.bounding_box(@entries.map(&:rectangle))
    end
  end

  def self.normalize_rectangle(rectangle)
    unless rectangle.is_a?(Array) && rectangle.size == 4 &&
           rectangle.all? { |value| value.is_a?(Numeric) }
      raise ArgumentError, "rectangle must be [min_x, min_y, max_x, max_y]"
    end

    min_x, min_y, max_x, max_y = rectangle
    if min_x > max_x || min_y > max_y
      raise ArgumentError, "rectangle minimum coordinates must not exceed maximum coordinates"
    end

    rectangle.dup
  end

  def self.bounding_box(rectangles)
    return nil if rectangles.empty?

    min_x = rectangles.map { |rectangle| rectangle[0] }.min
    min_y = rectangles.map { |rectangle| rectangle[1] }.min
    max_x = rectangles.map { |rectangle| rectangle[2] }.max
    max_y = rectangles.map { |rectangle| rectangle[3] }.max
    [min_x, min_y, max_x, max_y]
  end

  def self.rectangles_intersect?(first, second)
    first[0] <= second[2] && second[0] <= first[2] &&
      first[1] <= second[3] && second[1] <= first[3]
  end

  def self.rectangle_contains?(outer, inner)
    outer[0] <= inner[0] && outer[1] <= inner[1] &&
      inner[2] <= outer[2] && inner[3] <= outer[3]
  end

  def self.area(rectangle)
    (rectangle[2] - rectangle[0]) * (rectangle[3] - rectangle[1])
  end

  class << self
    alias_method :intersects?, :rectangles_intersect?
    alias_method :contains?, :rectangle_contains?
  end

  def initialize(entries = nil, max_entries = 4)
    if entries.is_a?(Integer)
      max_entries = entries
      entries = nil
    end

    unless max_entries.is_a?(Integer) && max_entries >= 3
      raise ArgumentError, "maximum node capacity must be an integer greater than or equal to 3"
    end

    @max_entries = max_entries
    @min_entries = max_entries / 2
    @root = Node.new(true)
    @entries = {}
    @size = 0

    if entries
      unless entries.respond_to?(:each)
        raise ArgumentError, "entries must respond to #each"
      end

      entries.each { |(id, rectangle)| insert(id, rectangle) }
    end
  end

  attr_reader :size, :max_entries, :root
  alias_method :capacity, :max_entries

  def empty?
    @size.zero?
  end

  def insert(id, rectangle)
    rectangle = self.class.normalize_rectangle(rectangle)
    old_rectangle = delete(id)
    entry = Entry.new(id, rectangle, nil)

    split = insert_entry(@root, entry)
    replace_root_with_split(split) if split

    @entries[id] = rectangle
    @size += 1
    rectangle.dup
  end
  alias_method :[]=, :insert
  alias_method :push, :insert
  alias_method :add, :insert
  alias_method :update, :insert

  def delete(id)
    return nil unless @entries.key?(id)

    rectangle = @entries.fetch(id)
    orphaned = []
    deleted, _root_underflowed = delete_entry(@root, id, rectangle, orphaned)
    return nil unless deleted

    orphaned.sort_by { |_, level| -level }.each do |entry, level|
      insert_existing(entry, level)
    end
    shrink_root

    @entries.delete(id)
    @size -= 1
    rectangle
  end
  alias_method :remove, :delete

  def get(id)
    rectangle = @entries[id]
    rectangle && rectangle.dup
  end
  alias_method :[], :get
  alias_method :rectangle, :get

  def has_key?(id)
    @entries.key?(id)
  end
  alias_method :key?, :has_key?
  alias_method :include?, :has_key?

  def search(rectangle, mode = :intersects)
    query = self.class.normalize_rectangle(rectangle)
    mode = normalize_search_mode(mode)
    results = []
    search_node(@root, query, mode, results)
    results
  end

  alias_method :find, :search

  def find_intersecting(rectangle)
    search(rectangle, :intersects)
  end
  alias_method :intersects, :find_intersecting
  alias_method :intersection, :find_intersecting
  alias_method :search_intersecting, :find_intersecting
  alias_method :intersecting, :find_intersecting
  alias_method :query, :find_intersecting

  def find_contained(rectangle)
    search(rectangle, :contained)
  end
  alias_method :contained_by, :find_contained
  alias_method :inside, :find_contained
  alias_method :contained_in, :find_contained
  alias_method :search_contained, :find_contained

  def find_containing(rectangle)
    search(rectangle, :containing)
  end
  alias_method :containers_of, :find_containing
  alias_method :containing, :find_containing
  alias_method :search_containing, :find_containing

  def each(&block)
    return enum_for(:each) unless block_given?

    @entries.each do |id, rectangle|
      yield(id, rectangle.dup)
    end
  end
  alias_method :each_entry, :each

  def to_h
    @entries.transform_values(&:dup)
  end

  def valid?
    return false unless @size == @entries.size
    return @root.entries.empty? if @root.leaf? && @root.entries.empty?

    validate_node(@root, true)
  end

  private

  def insert_entry(node, entry)
    if node.leaf?
      node.entries << entry
      return node.entries.size > @max_entries ? split_node(node) : nil
    end

    chosen = choose_subtree(node.entries, entry.rectangle)
    split = insert_entry(chosen.child, entry)
    chosen.rectangle = chosen.child.bounding_box

    if split
      node.entries.delete(chosen)
      node.entries.concat(split_entries(split))
      return node.entries.size > @max_entries ? split_node(node) : nil
    end

    nil
  end

  def insert_existing(entry, level)
    split = insert_at_level(@root, entry, level)
    replace_root_with_split(split) if split
  end

  def insert_at_level(node, entry, level)
    if node.entries.empty?
      if level.zero?
        node.leaf = true
        node.entries << entry
        return node.entries.size > @max_entries ? split_node(node) : nil
      else
        node.leaf = false
        node.entries << entry
        return node.entries.size > @max_entries ? split_node(node) : nil
      end
    elsif node_height(node) == level
      node.entries << entry
      return node.entries.size > @max_entries ? split_node(node) : nil
    end

    chosen = choose_subtree(node.entries, entry.rectangle)
    split = insert_at_level(chosen.child, entry, level)
    chosen.rectangle = chosen.child.bounding_box

    if split
      node.entries.delete(chosen)
      node.entries.concat(split_entries(split))
      return node.entries.size > @max_entries ? split_node(node) : nil
    end

    nil
  end

  def replace_root_with_split(nodes)
    @root = Node.new(false)
    @root.entries.concat(split_entries(nodes))
  end

  def shrink_root
    return if @root.leaf?

    if @root.entries.empty?
      @root = Node.new(true)
    elsif @root.entries.size == 1
      @root = @root.entries.first.child
    end
  end

  def choose_subtree(entries, rectangle)
    entries.min_by do |entry|
      [enlarged_area(entry.rectangle, rectangle), self.class.area(entry.rectangle)]
    end
  end

  def enlarged_area(first, second)
    combined = union_rectangle(first, second)
    self.class.area(combined) - self.class.area(first)
  end

  def split_node(node)
    entries = node.entries
    first_index, second_index = choose_seeds(entries)
    groups = [[entries[first_index]], [entries[second_index]]]
    boxes = [entries[first_index].rectangle.dup, entries[second_index].rectangle.dup]

    entries.each_with_index do |entry, index|
      next if index == first_index || index == second_index

      forced_group = forced_group(groups, entries.size)
      group = forced_group || choose_group(groups, boxes, entry.rectangle)
      groups[group] << entry
      boxes[group] = union_rectangle(boxes[group], entry.rectangle)
    end

    left = Node.new(node.leaf?)
    right = Node.new(node.leaf?)
    left.entries = groups[0]
    right.entries = groups[1]
    [left, right]
  end

  def choose_seeds(entries)
    best = nil

    entries.each_with_index do |first, first_index|
      (first_index + 1...entries.size).each do |second_index|
        second = entries[second_index]
        combined = union_rectangle(first.rectangle, second.rectangle)
        waste = self.class.area(combined) -
          self.class.area(first.rectangle) - self.class.area(second.rectangle)
        candidate = [waste, first_index, second_index]
        best = candidate if best.nil? || waste > best.first
      end
    end

    [best[1], best[2]]
  end

  def forced_group(groups, total_entries)
    remaining = total_entries - groups.sum(&:size)
    return 0 if groups[0].size + remaining == @min_entries
    return 1 if groups[1].size + remaining == @min_entries
    nil
  end

  def choose_group(groups, boxes, rectangle)
    enlargements = boxes.map { |box| enlarged_area(box, rectangle) }
    return enlargements[0] < enlargements[1] ? 0 : 1 if enlargements[0] != enlargements[1]

    areas = boxes.map { |box| self.class.area(box) }
    return 0 if areas[0] < areas[1]
    return 1 if areas[1] < areas[0]
    groups[0].size <= groups[1].size ? 0 : 1
  end

  def split_entries(nodes)
    nodes.map { |node| Entry.new(nil, node.bounding_box, node) }
  end

  def union_rectangle(first, second)
    [[first[0], second[0]].min, [first[1], second[1]].min,
     [first[2], second[2]].max, [first[3], second[3]].max]
  end

  def delete_entry(node, id, rectangle, orphaned)
    if node.leaf?
      entry = node.entries.find do |candidate|
        candidate.id == id && candidate.rectangle == rectangle
      end
      return nil unless entry

      node.entries.delete(entry)
      if node != @root && node.entries.size < @min_entries
        node.entries.each { |remaining| orphaned << [remaining, 0] }
        node.entries.clear
      end
      return [entry, node.entries.empty?]
    end

    result = nil

    node.entries.each do |entry|
      next unless self.class.rectangle_contains?(entry.rectangle, rectangle)

      result, child_underflowed = delete_entry(
        entry.child, id, rectangle, orphaned
      )
      next unless result

      if child_underflowed
        node.entries.delete(entry)
      else
        entry.rectangle = entry.child.bounding_box
      end
      break
    end

    return nil unless result

    underflowed = node != @root && node.entries.size < @min_entries
    if underflowed
      node.entries.each do |entry|
        level = entry.child ? node_height(entry.child) + 1 : 0
        orphaned << [entry, level]
      end
      node.entries.clear
    end

    [result, underflowed]
  end

  def node_height(node)
    return 0 if node.entries.empty?
    node.leaf? ? 0 : 1 + node_height(node.entries.first.child)
  end

  def search_node(node, query, mode, results)
    if node.leaf?
      node.entries.each do |entry|
        results << entry.id if rectangles_match?(entry.rectangle, query, mode)
      end
      return
    end

    node.entries.each do |entry|
      next unless should_descend?(entry.rectangle, query, mode)
      search_node(entry.child, query, mode, results)
    end
  end

  def should_descend?(candidate, query, mode)
    case mode
    when :intersects, :contained
      self.class.rectangles_intersect?(candidate, query)
    when :containing
      self.class.rectangle_contains?(candidate, query)
    else
      raise ArgumentError, "unknown search mode #{mode}"
    end
  end

  def rectangles_match?(candidate, query, mode)
    case mode
    when :intersects
      self.class.rectangles_intersect?(candidate, query)
    when :contained
      self.class.rectangle_contains?(query, candidate)
    when :containing
      self.class.rectangle_contains?(candidate, query)
    else
      raise ArgumentError, "unknown search mode #{mode}"
    end
  end

  def normalize_search_mode(mode)
    case mode
    when :intersects, :intersect, :intersecting, :intersection
      :intersects
    when :contained, :contained_in, :inside, :contain
      :contained
    when :containing, :contains_query
      :containing
    else
      raise ArgumentError, "unknown search mode #{mode}"
    end
  end

  def validate_node(node, is_root)
    return false if node.entries.size > @max_entries
    return false if !is_root && node.entries.size < @min_entries

    expected_child_leaf = node.entries.first.child.leaf? if !node.leaf? && node.entries.any?

    node.entries.all? do |entry|
      expected = entry.child ? entry.child.bounding_box : entry.rectangle
      next false unless entry.rectangle == expected
      next false if node.leaf? != (entry.child.nil?)
      next false if entry.child && entry.child.leaf? != expected_child_leaf
      entry.child.nil? || validate_node(entry.child, false)
    end
  end
end
