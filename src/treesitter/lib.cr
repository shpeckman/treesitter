# src/treesitter/lib.cr
@[Link(ldflags: "#{__DIR__}/../../vendor/build/libgrammars.a #{__DIR__}/../../vendor/build/libtree-sitter.a")]
lib LibTreeSitter
  alias TSParser = Void*
  alias TSTree = Void*
  alias TSLanguage = Void*
  alias TSQuery = Void*
  alias TSQueryCursor = Void*

  struct Point
    row    : UInt32
    column : UInt32
  end

  struct Range
    start_point : Point
    end_point   : Point
    start_byte  : UInt32
    end_byte    : UInt32
  end

  struct Node
    context : UInt32[4]
    id      : Void*
    tree    : TSTree
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

  enum QueryPredicateStepType
    Done
    Capture
    String
  end

  struct QueryPredicateStep
    type     : QueryPredicateStepType
    value_id : UInt32
  end

  struct InputEdit
    start_byte    : UInt32
    old_end_byte  : UInt32
    new_end_byte  : UInt32
    start_point   : Point
    old_end_point : Point
    new_end_point : Point
  end

  enum InputEncoding
    UTF8
    UTF16LE
    UTF16BE
    Custom
  end

  struct Input
    payload  : Void*
    read     : (Void*, UInt32, Point, UInt32*) -> UInt8*
    encoding : InputEncoding
    decode   : Void*
  end

  enum QueryError
    None      = 0
    Syntax    = 1
    NodeType  = 2
    Field     = 3
    Capture   = 4
    Structure = 5
    Language  = 6
  end

  fun ts_parser_new : TSParser
  fun ts_parser_delete(parser : TSParser)
  fun ts_parser_set_language(parser : TSParser, language : TSLanguage) : Bool
  fun ts_parser_parse(parser : TSParser, old_tree : TSTree, input : Input) : TSTree
  fun ts_parser_parse_string(parser : TSParser, old_tree : TSTree, string : UInt8*, length : UInt32) : TSTree
  fun ts_parser_set_included_ranges(parser : TSParser, ranges : Range*, count : UInt32) : Bool

  fun ts_tree_copy(tree : TSTree) : TSTree
  fun ts_tree_root_node(tree : TSTree) : Node
  fun ts_tree_delete(tree : TSTree)
  fun ts_tree_edit(tree : TSTree, edit : InputEdit*)
  fun ts_tree_get_changed_ranges(old_tree : TSTree, new_tree : TSTree, length : UInt32*) : Range*

  fun ts_node_type(node : Node) : UInt8*
  fun ts_node_start_byte(node : Node) : UInt32
  fun ts_node_end_byte(node : Node) : UInt32
  fun ts_node_start_point(node : Node) : Point
  fun ts_node_end_point(node : Node) : Point
  fun ts_node_is_null(node : Node) : Bool
  fun ts_node_is_named(node : Node) : Bool
  fun ts_node_is_error(node : Node) : Bool
  fun ts_node_is_missing(node : Node) : Bool
  fun ts_node_has_error(node : Node) : Bool
  fun ts_node_child_count(node : Node) : UInt32
  fun ts_node_named_child_count(node : Node) : UInt32
  fun ts_node_child(node : Node, index : UInt32) : Node
  fun ts_node_named_child(node : Node, index : UInt32) : Node
  fun ts_node_parent(node : Node) : Node
  fun ts_node_string(node : Node) : UInt8*
  fun ts_node_descendant_for_byte_range(node : Node, start : UInt32, stop : UInt32) : Node
  fun ts_node_named_descendant_for_byte_range(node : Node, start : UInt32, stop : UInt32) : Node
  fun ts_node_child_by_field_name(node : Node, name : UInt8*, name_length : UInt32) : Node

  fun ts_query_new(language : TSLanguage, source : UInt8*, source_len : UInt32, error_offset : UInt32*, error_type : QueryError*) : TSQuery
  fun ts_query_delete(query : TSQuery)
  fun ts_query_pattern_count(query : TSQuery) : UInt32
  fun ts_query_capture_count(query : TSQuery) : UInt32
  fun ts_query_capture_name_for_id(query : TSQuery, index : UInt32, length : UInt32*) : UInt8*
  fun ts_query_string_value_for_id(query : TSQuery, index : UInt32, length : UInt32*) : UInt8*
  fun ts_query_predicates_for_pattern(query : TSQuery, pattern_index : UInt32, step_count : UInt32*) : QueryPredicateStep*

  fun ts_query_cursor_new : TSQueryCursor
  fun ts_query_cursor_delete(cursor : TSQueryCursor)
  fun ts_query_cursor_exec(cursor : TSQueryCursor, query : TSQuery, node : Node)
  fun ts_query_cursor_set_byte_range(cursor : TSQueryCursor, start_byte : UInt32, end_byte : UInt32) : Bool
  fun ts_query_cursor_next_match(cursor : TSQueryCursor, match : QueryMatch*) : Bool

  fun ts_language_abi_version(language : TSLanguage) : UInt32

  fun tree_sitter_json : TSLanguage
  fun tree_sitter_crystal : TSLanguage
  fun tree_sitter_python : TSLanguage
  fun tree_sitter_c : TSLanguage
  fun tree_sitter_bash : TSLanguage
end
