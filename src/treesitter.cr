# src/treesitter.cr

require "./tree_sitter/lib"
require "./tree_sitter/error"
require "./tree_sitter/values"
require "./tree_sitter/language"
require "./tree_sitter/tree"
require "./tree_sitter/node"
require "./tree_sitter/parser"
require "./tree_sitter/source"
require "./tree_sitter/predicate"
require "./tree_sitter/query"

# Bindings to the Tree-sitter C library (0.25 or newer, linked through `pkg-config`): grammars loaded from shared
# libraries at run time (`Language.load`), incremental parsing (`Parser`, `Tree#edit`), syntax nodes (`Node`) and
# queries with the common predicates (`Query`). Offsets are bytes into UTF-8 text; points are rows and byte columns.
module TreeSitter
end
