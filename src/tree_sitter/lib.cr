# src/tree_sitter/lib.cr

@[Link("tree-sitter")]
lib LibTreeSitter
  struct Point
    row    : UInt32
    column : UInt32
  end

  struct InputEdit
    start_byte    : UInt32
    old_end_byte  : UInt32
    new_end_byte  : UInt32
    start_point   : Point
    old_end_point : Point
    new_end_point : Point
  end

  struct Node
    context : StaticArray(UInt32, 4)
    id      : Void*
    tree    : Void*
  end

  struct Range
    start_point : Point
    end_point   : Point
    start_byte  : UInt32
    end_byte    : UInt32
  end

  enum InputEncoding
    UTF8
    UTF16LE
    UTF16BE
    Custom
  end

  alias ReadFunction = (Void*, UInt32, Point, UInt32*) -> UInt8*

  struct Input
    payload  : Void*
    read     : ReadFunction
    encoding : InputEncoding
    decode   : Void*
  end

  struct ParseState
    payload             : Void*
    current_byte_offset : UInt32
    has_error           : Bool
  end

  alias ProgressFunction = ParseState* -> Bool

  struct ParseOptions
    payload           : Void*
    progress_callback : ProgressFunction
  end

  struct QueryCapture
    node  : Node
    index : UInt32
  end

  struct QueryMatch
    id            : UInt32
    pattern_index : UInt16
    capture_count : UInt16
    captures      : QueryCapture*
  end

  enum PredicateStepType
    Done
    Capture
    String
  end

  struct QueryPredicateStep
    step_type : PredicateStepType
    value_id  : UInt32
  end

  enum QueryError
    None
    Syntax
    NodeType
    Field
    Capture
    Structure
    Language
  end

  fun ts_parser_new : Void*
  fun ts_parser_delete(parser : Void*)
  fun ts_parser_set_language(parser : Void*, language : Void*) : Bool
  fun ts_parser_parse(parser : Void*, old_tree : Void*, input : Input) : Void*
  fun ts_parser_parse_with_options(parser : Void*, old_tree : Void*, input : Input, options : ParseOptions) : Void*
  fun ts_parser_set_included_ranges(parser : Void*, ranges : Range*, count : UInt32) : Bool
  fun ts_parser_reset(parser : Void*)
  fun ts_parser_parse_string(parser : Void*, old_tree : Void*, string : UInt8*, length : UInt32) : Void*

  fun ts_tree_copy(tree : Void*) : Void*
  fun ts_tree_delete(tree : Void*)
  fun ts_tree_root_node(tree : Void*) : Node
  fun ts_tree_edit(tree : Void*, edit : InputEdit*)
  fun ts_tree_get_changed_ranges(old_tree : Void*, new_tree : Void*, length : UInt32*) : Range*

  fun ts_node_type(node : Node) : UInt8*
  fun ts_node_start_byte(node : Node) : UInt32
  fun ts_node_end_byte(node : Node) : UInt32
  fun ts_node_start_point(node : Node) : Point
  fun ts_node_end_point(node : Node) : Point
  fun ts_node_is_null(node : Node) : Bool
  fun ts_node_is_named(node : Node) : Bool
  fun ts_node_is_missing(node : Node) : Bool
  fun ts_node_is_extra(node : Node) : Bool
  fun ts_node_is_error(node : Node) : Bool
  fun ts_node_has_error(node : Node) : Bool
  fun ts_node_parent(node : Node) : Node
  fun ts_node_child(node : Node, index : UInt32) : Node
  fun ts_node_child_count(node : Node) : UInt32
  fun ts_node_named_child(node : Node, index : UInt32) : Node
  fun ts_node_named_child_count(node : Node) : UInt32
  fun ts_node_child_by_field_name(node : Node, name : UInt8*, length : UInt32) : Node
  fun ts_node_next_sibling(node : Node) : Node
  fun ts_node_prev_sibling(node : Node) : Node
  fun ts_node_next_named_sibling(node : Node) : Node
  fun ts_node_prev_named_sibling(node : Node) : Node
  fun ts_node_descendant_for_byte_range(node : Node, start : UInt32, stop : UInt32) : Node
  fun ts_node_named_descendant_for_byte_range(node : Node, start : UInt32, stop : UInt32) : Node
  fun ts_node_eq(node : Node, other : Node) : Bool

  fun ts_query_new(language : Void*, source : UInt8*, length : UInt32, error_offset : UInt32*, error_type : QueryError*) : Void*
  fun ts_query_delete(query : Void*)
  fun ts_query_pattern_count(query : Void*) : UInt32
  fun ts_query_capture_count(query : Void*) : UInt32
  fun ts_query_capture_name_for_id(query : Void*, index : UInt32, length : UInt32*) : UInt8*
  fun ts_query_string_value_for_id(query : Void*, index : UInt32, length : UInt32*) : UInt8*
  fun ts_query_predicates_for_pattern(query : Void*, pattern : UInt32, step_count : UInt32*) : QueryPredicateStep*

  fun ts_query_cursor_new : Void*
  fun ts_query_cursor_delete(cursor : Void*)
  fun ts_query_cursor_exec(cursor : Void*, query : Void*, node : Node)
  fun ts_query_cursor_set_byte_range(cursor : Void*, start : UInt32, stop : UInt32) : Bool
  fun ts_query_cursor_next_match(cursor : Void*, match : QueryMatch*) : Bool
  fun ts_query_cursor_next_capture(cursor : Void*, match : QueryMatch*, capture_index : UInt32*) : Bool

  fun ts_language_abi_version(language : Void*) : UInt32
end
