# src/tree_sitter/node.cr

module TreeSitter
  # A node of a `Tree`: its type, byte range, points and neighbors. Navigation returns `nil` where there is no node.
  # A node is a value; it stays valid while its tree is not edited.
  struct Node
    # The tree this node belongs to.
    getter tree : Tree

    def initialize(@raw : LibTreeSitter::Node, @tree : Tree)
    end

    # The grammar's name for this kind of node (`"pair"`, `","`, `"ERROR"`).
    def type : String
      String.new(LibTreeSitter.ts_node_type(@raw))
    end

    # Byte offset where the node starts.
    @[AlwaysInline]
    def start_byte : Int32
      LibTreeSitter.ts_node_start_byte(@raw).to_i
    end

    # Byte offset where the node ends (exclusive).
    @[AlwaysInline]
    def end_byte : Int32
      LibTreeSitter.ts_node_end_byte(@raw).to_i
    end

    # The node's bytes as an exclusive range.
    def range : Range(Int32, Int32)
      start_byte...end_byte
    end

    # Where the node starts.
    def start_point : Point
      Point.of(LibTreeSitter.ts_node_start_point(@raw))
    end

    # Where the node ends.
    def end_point : Point
      Point.of(LibTreeSitter.ts_node_end_point(@raw))
    end

    # Whether the grammar names this node (rules, not anonymous tokens such as `","`).
    def named? : Bool
      LibTreeSitter.ts_node_is_named(@raw)
    end

    # Whether the parser inserted this zero-width node to recover from an error.
    def missing? : Bool
      LibTreeSitter.ts_node_is_missing(@raw)
    end

    # Whether this node is extra, such as a comment, which may appear anywhere.
    def extra? : Bool
      LibTreeSitter.ts_node_is_extra(@raw)
    end

    # Whether this node is an `ERROR` node, text the parser could not fit.
    def error? : Bool
      LibTreeSitter.ts_node_is_error(@raw)
    end

    # Whether this node is or contains an error or a missing node.
    def has_error? : Bool
      LibTreeSitter.ts_node_has_error(@raw)
    end

    # The enclosing node, `nil` for the root.
    def parent : Node?
      wrap(LibTreeSitter.ts_node_parent(@raw))
    end

    # Number of children, anonymous ones included.
    def child_count : Int32
      LibTreeSitter.ts_node_child_count(@raw).to_i
    end

    # The child at *index*, anonymous ones included.
    def child(index : Int32) : Node?
      return nil unless 0 <= index < child_count
      wrap(LibTreeSitter.ts_node_child(@raw, index.to_u32))
    end

    # Number of named children.
    def named_child_count : Int32
      LibTreeSitter.ts_node_named_child_count(@raw).to_i
    end

    # The named child at *index*.
    def named_child(index : Int32) : Node?
      return nil unless 0 <= index < named_child_count
      wrap(LibTreeSitter.ts_node_named_child(@raw, index.to_u32))
    end

    # The child in the grammar field *name* (`"key"`, `"body"`).
    def field(name : String) : Node?
      wrap(LibTreeSitter.ts_node_child_by_field_name(@raw, name, name.bytesize.to_u32))
    end

    # The next sibling, anonymous ones included.
    def next_sibling : Node?
      wrap(LibTreeSitter.ts_node_next_sibling(@raw))
    end

    # The previous sibling, anonymous ones included.
    def previous_sibling : Node?
      wrap(LibTreeSitter.ts_node_prev_sibling(@raw))
    end

    # The next named sibling.
    def next_named_sibling : Node?
      wrap(LibTreeSitter.ts_node_next_named_sibling(@raw))
    end

    # The previous named sibling.
    def previous_named_sibling : Node?
      wrap(LibTreeSitter.ts_node_prev_named_sibling(@raw))
    end

    # The smallest node within this one that spans the bytes *from*...*to*.
    def descendant(from : Int32, to : Int32) : Node?
      wrap(LibTreeSitter.ts_node_descendant_for_byte_range(@raw, from.to_u32, to.to_u32))
    end

    # The smallest named node within this one that spans the bytes *from*...*to*.
    def named_descendant(from : Int32, to : Int32) : Node?
      wrap(LibTreeSitter.ts_node_named_descendant_for_byte_range(@raw, from.to_u32, to.to_u32))
    end

    # Whether *other* is the same node.
    def ==(other : Node) : Bool
      LibTreeSitter.ts_node_eq(@raw, other.to_unsafe)
    end

    # The C value.
    def to_unsafe : LibTreeSitter::Node
      @raw
    end

    private def wrap(raw : LibTreeSitter::Node) : Node?
      LibTreeSitter.ts_node_is_null(raw) ? nil : Node.new(raw, @tree)
    end
  end
end
