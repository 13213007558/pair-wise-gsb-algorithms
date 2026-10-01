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
    * Set reconciliation
      - Invertible Bloom Lookup Table Algorithms::IBLT

## SYNOPSIS:

    require 'rubygems'
    require 'algorithms'

    max_heap = Containers::MaxHeap.new

    # To not have to type "Containers::" before each class, use:
    include Containers
    max_heap = MaxHeap.new

    left = Algorithms::IBLT.new(200, 3).insert_all(left_ids)
    right = Algorithms::IBLT.new(200, 3).insert_all(right_ids)
    result = (left - right).recover
    result.status       # :complete, :partial, :failed, or :no_difference
    result.left_only
    result.right_only
    result.residual     # Present whenever recovery is incomplete

    IDs use set semantics, so repeated insertion is ignored. Use
    result.no_difference? to distinguish equal sets from a completed reconciliation.

## REQUIREMENTS:

* Ruby 1.8, Ruby 1.9, JRuby
* C extensions (optional, but very much recommended for vast performance benefits)

## LICENSE:

See [LICENSE.md](LICENSE.md).
