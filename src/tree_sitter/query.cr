# src/tree_sitter/query.cr

module TreeSitter
  # One captured node of a query match: the node, its capture `id` and `name` (`"keyword"`, `"function.outer"`) and
  # the index of the `pattern` that matched.
  record Capture, node : Node, id : Int32, name : String, pattern : Int32

  # One match of a query pattern with all of its captures.
  record Match, pattern : Int32, captures : Array(Capture) do
    # The first node captured as *name*.
    def [](name : String) : Node?
      @captures.find(&.name.==(name)).try(&.node)
    end

    # Every node captured as *name*, for quantified captures.
    def nodes(name : String) : Array(Node)
      @captures.compact_map { |capture| capture.name == name ? capture.node : nil }
    end
  end

  # A compiled query (S-expression patterns with `@captures` and predicates) for one `Language`. Run it over a node
  # with `each_capture` (captures in text order, for highlighting) or `each_match` (whole matches).
  class Query
    # The grammar the query was compiled for.
    getter language : Language
    # Capture names by id.
    getter capture_names : Array(String)
    # Number of patterns.
    getter pattern_count : Int32

    # Compiles *source*; raises `QueryError` where the grammar rejects it.
    def initialize(@language : Language, source : String)
      offset = 0_u32
      kind = LibTreeSitter::QueryError::None
      @pointer = LibTreeSitter.ts_query_new(@language, source, source.bytesize.to_u32, pointerof(offset), pointerof(kind))
      raise QueryError.new(offset.to_i, QueryError::Kind.new(kind.value), source) if @pointer.null?
      @capture_names = Array.new(LibTreeSitter.ts_query_capture_count(@pointer).to_i) do |id|
        length = 0_u32
        String.new(LibTreeSitter.ts_query_capture_name_for_id(@pointer, id.to_u32, pointerof(length)), length)
      end
      @pattern_count = LibTreeSitter.ts_query_pattern_count(@pointer).to_i
      @predicates = Array(Array(Predicate)).new(@pattern_count) { |pattern| Predicate.list(@pointer, pattern) }
      @properties = Array(Hash(String, String)).new(@pattern_count) { |pattern| Predicate.properties(@pointer, pattern) }
    end

    # The predicates of *pattern*.
    def predicates(pattern : Int32) : Array(Predicate)
      @predicates[pattern]
    end

    # The `#set!` properties of *pattern* (`injection.language` → `"lua"`); a key set without a value maps to `""`.
    def properties(pattern : Int32) : Hash(String, String)
      @properties[pattern]
    end

    # Yields every capture under *node* in text order, within the byte *range* when given, skipping matches whose
    # predicates fail on the text read from *source*.
    def each_capture(node : Node, source : Source, range : Range(Int32, Int32)? = nil, & : Capture ->) : Nil
      run(node, range) do |cursor|
        match = LibTreeSitter::QueryMatch.new
        index = 0_u32
        last = UInt32::MAX
        passed = false
        while LibTreeSitter.ts_query_cursor_next_capture(cursor, pointerof(match), pointerof(index))
          unless match.id == last
            last = match.id
            passed = passes?(match, node.tree, source)
          end
          next unless passed
          raw = match.captures[index]
          yield Capture.new(Node.new(raw.node, node.tree), raw.index.to_i, @capture_names[raw.index], match.pattern_index.to_i)
        end
      end
    end

    # `each_capture` over the text of a string.
    def each_capture(node : Node, source : String, range : Range(Int32, Int32)? = nil, & : Capture ->) : Nil
      each_capture(node, StringSource.new(source), range) { |capture| yield capture }
    end

    # Yields every match under *node*, within the byte *range* when given, whose predicates pass on *source*.
    def each_match(node : Node, source : Source, range : Range(Int32, Int32)? = nil, & : Match ->) : Nil
      run(node, range) do |cursor|
        match = LibTreeSitter::QueryMatch.new
        while LibTreeSitter.ts_query_cursor_next_match(cursor, pointerof(match))
          next unless passes?(match, node.tree, source)
          captures = Array(Capture).new(match.capture_count.to_i) do |index|
            raw = match.captures[index]
            Capture.new(Node.new(raw.node, node.tree), raw.index.to_i, @capture_names[raw.index], match.pattern_index.to_i)
          end
          yield Match.new(match.pattern_index.to_i, captures)
        end
      end
    end

    # `each_match` over the text of a string.
    def each_match(node : Node, source : String, range : Range(Int32, Int32)? = nil, & : Match ->) : Nil
      each_match(node, StringSource.new(source), range) { |match| yield match }
    end

    # The C pointer.
    def to_unsafe : Void*
      @pointer
    end

    def finalize
      LibTreeSitter.ts_query_delete(@pointer)
    end

    private def passes?(match : LibTreeSitter::QueryMatch, tree : Tree, source : Source) : Bool
      predicates = @predicates[match.pattern_index]
      return true if predicates.empty?
      captures = Slice.new(match.captures, match.capture_count.to_i)
      predicates.all?(&.satisfied?(captures, tree, source))
    end

    private def run(node : Node, range : Range(Int32, Int32)?, & : Void* ->) : Nil
      cursor = LibTreeSitter.ts_query_cursor_new
      begin
        if range
          stop = range.excludes_end? ? range.end : range.end + 1
          LibTreeSitter.ts_query_cursor_set_byte_range(cursor, range.begin.to_u32, stop.to_u32)
        end
        LibTreeSitter.ts_query_cursor_exec(cursor, @pointer, node.to_unsafe)
        yield cursor
      ensure
        LibTreeSitter.ts_query_cursor_delete(cursor)
      end
    end
  end
end
