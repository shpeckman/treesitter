# src/treesitter/tree.cr
module TreeSitter
  record Region, start_byte : Int32, end_byte : Int32, first_row : Int32, last_row : Int32

  struct Node
    getter tree : Tree

    def initialize(@raw : LibTreeSitter::Node, @tree : Tree)
    end

    def to_unsafe : LibTreeSitter::Node
      @raw
    end

    def type : String
      String.new(LibTreeSitter.ts_node_type(@raw))
    end

    def start_byte : Int32
      LibTreeSitter.ts_node_start_byte(@raw).to_i32
    end

    def end_byte : Int32
      LibTreeSitter.ts_node_end_byte(@raw).to_i32
    end

    def bytes : Range(Int32, Int32)
      start_byte...end_byte
    end

    def start_point : Scribe::Point
      TreeSitter.point(LibTreeSitter.ts_node_start_point(@raw))
    end

    def end_point : Scribe::Point
      TreeSitter.point(LibTreeSitter.ts_node_end_point(@raw))
    end

    def null? : Bool
      LibTreeSitter.ts_node_is_null(@raw)
    end

    def named? : Bool
      LibTreeSitter.ts_node_is_named(@raw)
    end

    def error? : Bool
      LibTreeSitter.ts_node_is_error(@raw)
    end

    def missing? : Bool
      LibTreeSitter.ts_node_is_missing(@raw)
    end

    def has_error? : Bool
      LibTreeSitter.ts_node_has_error(@raw)
    end

    def child_count : Int32
      LibTreeSitter.ts_node_child_count(@raw).to_i32
    end

    def named_child_count : Int32
      LibTreeSitter.ts_node_named_child_count(@raw).to_i32
    end

    def child(index : Int32) : Node?
      wrap(LibTreeSitter.ts_node_child(@raw, index.to_u32))
    end

    def named_child(index : Int32) : Node?
      wrap(LibTreeSitter.ts_node_named_child(@raw, index.to_u32))
    end

    def children : Array(Node)
      Array(Node).new(child_count) { |index| Node.new(LibTreeSitter.ts_node_child(@raw, index.to_u32), @tree) }
    end

    def named_children : Array(Node)
      Array(Node).new(named_child_count) { |index| Node.new(LibTreeSitter.ts_node_named_child(@raw, index.to_u32), @tree) }
    end

    def field(name : String) : Node?
      wrap(LibTreeSitter.ts_node_child_by_field_name(@raw, name, name.bytesize.to_u32))
    end

    def parent : Node?
      wrap(LibTreeSitter.ts_node_parent(@raw))
    end

    def descendant(from : Int32, to : Int32 = from, named : Bool = true) : Node?
      found = named ? LibTreeSitter.ts_node_named_descendant_for_byte_range(@raw, from.to_u32, to.to_u32) : LibTreeSitter.ts_node_descendant_for_byte_range(@raw, from.to_u32, to.to_u32)
      wrap(found)
    end

    def text(source : String) : String
      source.byte_slice(start_byte, end_byte - start_byte)
    end

    def text(source : Scribe::Buffer) : String
      source.byte_text(start_byte, end_byte)
    end

    def sexp : String
      raw  = LibTreeSitter.ts_node_string(@raw)
      text = String.new(raw)
      LibC.free(raw.as(Void*))
      text
    end

    def to_s(io : IO) : Nil
      io << sexp
    end

    def inspect(io : IO) : Nil
      io << "#<TreeSitter::Node " << type << ' ' << start_byte << "..." << end_byte << '>'
    end

    private def wrap(raw : LibTreeSitter::Node) : Node?
      LibTreeSitter.ts_node_is_null(raw) ? nil : Node.new(raw, @tree)
    end
  end

  class Tree
    def initialize(@raw : LibTreeSitter::TSTree)
    end

    def finalize
      LibTreeSitter.ts_tree_delete(@raw)
    end

    def to_unsafe : LibTreeSitter::TSTree
      @raw
    end

    def root : Node
      Node.new(LibTreeSitter.ts_tree_root_node(@raw), self)
    end

    def copy : Tree
      Tree.new(LibTreeSitter.ts_tree_copy(@raw))
    end

    def edit(edit : LibTreeSitter::InputEdit) : Nil
      LibTreeSitter.ts_tree_edit(@raw, pointerof(edit))
    end

    def edit(change : Scribe::Change, buffer : Scribe::Buffer) : Nil
      start = buffer.byte_offset(change.from)
      edit(LibTreeSitter::InputEdit.new(
        start_byte: start.to_u32,
        old_end_byte: (start + change.removed.bytesize).to_u32,
        new_end_byte: (start + change.inserted.bytesize).to_u32,
        start_point: TreeSitter.point(change.start_point(buffer, Scribe::Units::Bytes)),
        old_end_point: TreeSitter.point(change.old_end_point(buffer, Scribe::Units::Bytes)),
        new_end_point: TreeSitter.point(change.new_end_point(buffer, Scribe::Units::Bytes))))
    end

    def changed_ranges(newer : Tree) : Array(Region)
      count  = 0_u32
      ranges = LibTreeSitter.ts_tree_get_changed_ranges(@raw, newer, pointerof(count))
      found = Array(Region).new(count) do |index|
        range = ranges[index]
        Region.new(range.start_byte.to_i32, range.end_byte.to_i32, range.start_point.row.to_i32, range.end_point.row.to_i32)
      end
      LibC.free(ranges.as(Void*)) unless ranges.null?
      found
    end

    def to_s(io : IO) : Nil
      root.to_s(io)
    end
  end

  def self.point(point : Scribe::Point) : LibTreeSitter::Point
    LibTreeSitter::Point.new(row: point.line.to_u32, column: point.column.to_u32)
  end

  def self.point(point : LibTreeSitter::Point) : Scribe::Point
    Scribe::Point.new(point.row.to_i32, point.column.to_i32)
  end
end
