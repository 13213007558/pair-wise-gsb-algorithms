# algorithms [![Ruby CI](https://github.com/kanwei/algorithms/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/kanwei/algorithms/actions/workflows/ci.yml)

[API Documentation](http://kanwei.github.io/algorithms/)

## DESCRIPTION:

Started as a [Google Summer of Code 2008](http://code.google.com/soc/2008/ruby/about.html) project

Written by [Kanwei Li](http://kanwei.com/), mentored by Austin Ziegler

## Original Proposal: ##

Using the right data structure or algorithm for the situation is an important
aspect of programming. In computer science literature, many data structures
and algorithms have been researched and extensively documented. However, there
is still no standard library in Ruby implementing useful structures and
algorithms like Red/Black Trees, tries, different sorting algorithms, etc.
This project will create such a library with documentation on when to use a
particular structure/algorithm. It will also come with a benchmark suite to
compare performance in different situations.

## COMPLETED:

    * Heaps              Containers::Heap, Containers::MaxHeap, Containers::MinHeap
    * Priority Queue     Containers::PriorityQueue
    * Deque              Containers::Deque, Containers::CDeque (C ext)
    * Stack              Containers::Stack
    * Queue              Containers::Queue
    * Red-Black Trees    Containers::RBTreeMap, Containers::CRBTreeMap (C ext)
    * Splay Trees        Containers::SplayTreeMap, Containers::CSplayTreeMap (C ext)
    * Tries              Containers::Trie
    * Suffix Array       Containers::SuffixArray
    * IBLT               Algorithms::IBLT

    * Search algorithms
      - Binary Search            Algorithms::Search.binary_search
      - Knuth-Morris-Pratt       Algorithms::Search.kmp_search
    * Sorting algorithms           
      - Bubble sort              Algorithms::Sort.bubble_sort
      - Comb sort                Algorithms::Sort.comb_sort
      - Selection sort           Algorithms::Sort.selection_sort
      - Heapsort                 Algorithms::Sort.heapsort
      - Insertion sort           Algorithms::Sort.insertion_sort
      - Shell sort               Algorithms::Sort.shell_sort
      - Quicksort                Algorithms::Sort.quicksort
      - Mergesort                Algorithms::Sort.mergesort
      - Dual-Pivot Quicksort     Algorithms::Sort.dualpivotquicksort

## SYNOPSIS:

    require 'rubygems'
    require 'algorithms'

    max_heap = Containers::MaxHeap.new

    # To not have to type "Containers::" before each class, use:
    include Containers
    max_heap = MaxHeap.new

    # Reconcile large fixed-width unsigned integer ID sets:
    left = Algorithms::IBLT.new(table_size: 128, key_bytes: 8)
    right = Algorithms::IBLT.new(table_size: 128, key_bytes: 8)
    [1, 2, 3].each { |id| left.insert(id) }
    [2, 3, 4].each { |id| right.insert(id) }
    result = (left - right).decode
    result.complete?    #=> true
    result.left_only    #=> [1]
    result.right_only   #=> [4]

    # Insertion has set semantics, so duplicate IDs in one service are ignored.
    # Exchange to_json / from_json instead of sending the full ID list.
    # When decode returns :incomplete, left_only and right_only are partial
    # and result.residual contains the cells that stopped peeling.

## REQUIREMENTS:

* Ruby 1.8, Ruby 1.9, JRuby
* C extensions (optional, but very much recommended for vast performance benefits)

## LICENSE:

See [LICENSE.md](LICENSE.md).
