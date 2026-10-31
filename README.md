# treesitter

Crystal bindings to the [Tree-sitter](https://tree-sitter.github.io) C library: grammars loaded from shared libraries at run time, incremental parsing from a string or a chunked reader, syntax nodes, and queries with the common predicates.

It binds the library and nothing more: no grammars are built in, and it knows nothing about editors. [asekii-editor](https://github.com/shpeckman/asekii-editor) builds highlighting and AST editing for [scribe](https://github.com/shpeckman/scribe) documents on it.

## Requirements

- Crystal 1.21 or newer
- libtree-sitter 0.25 or newer, found through `pkg-config` (Fedora: `tree-sitter-devel`; or build it from [the repository](https://github.com/tree-sitter/tree-sitter) with `make && sudo make install`)
- Grammars as shared libraries, for example the ones nvim-treesitter installs, or built with `tree-sitter build`

## Installation

```yaml
dependencies:
  treesitter:
    github: shpeckman/treesitter
```

```crystal
require "treesitter"
```

## Usage

```crystal
json   = TreeSitter::Language.load("/usr/lib64/libtree-sitter-json.so", "json")
parser = TreeSitter::Parser.new(json)
text   = %({"a": [1, 2]})
tree   = parser.parse(text)

root = tree.root
root.type                                  # => "document"
pair = root.named_child(0).not_nil!.named_child(0).not_nil!
pair.field("key").not_nil!.range           # => 1...4
pair.field("value").not_nil!.start_point   # => TreeSitter::Point.new(0, 6)
```

### Languages

`Language.load(path, name, symbol = "tree_sitter_<name>")` opens a grammar library and calls its entry function; dashes in the name become underscores in the default symbol. It raises `TreeSitter::Error` when the library or the symbol is missing, or when the grammar's ABI is outside `Language::MIN_ABI..Language::MAX_ABI` (13 to 15). A grammar linked into the program can be wrapped directly: `Language.new(tree_sitter_json(), "json")`. Loaded libraries stay open for the life of the process.

### Parsing

| Call | Parses |
| --- | --- |
| `parse(text, old_tree = nil)` | A string |
| `parse(old_tree = nil) { \|byte\| bytes }` | Text read in chunks: the block gets a byte offset and returns the bytes from there, of any length, and an empty slice at the end |

A chunk must stay unchanged until the next call; the parser keeps the last one alive. Raises `Error` when the parse does not finish.

To reparse after a change, describe it with `Tree#edit` and pass the old tree:

```crystal
tree = parser.parse("[1, 2]")
tree.edit(TreeSitter::Edit.new(start_byte: 5, old_end_byte: 5, new_end_byte: 8,
  start_point: TreeSitter::Point.new(0, 5), old_end_point: TreeSitter::Point.new(0, 5),
  new_end_point: TreeSitter::Point.new(0, 8)))
tree = parser.parse("[1, 2, 3]", tree)
```

Offsets are bytes into UTF-8 text. A `Point` is a zero-based row and a byte column. `Tree#copy` makes an independent copy, cheap to make, for use on another fiber.

### Nodes

`Node` is a value tied to its `Tree`, and it keeps the tree alive. Every navigation method returns `nil` where there is no node.

| Group | Methods |
| --- | --- |
| Identity | `type`, `named?`, `extra?`, `==` |
| Position | `start_byte`, `end_byte`, `range`, `start_point`, `end_point` |
| Errors | `error?` (an `ERROR` node), `missing?` (inserted by recovery, zero width), `has_error?` (either one inside) |
| Tree | `parent`, `child(i)`, `child_count`, `named_child(i)`, `named_child_count`, `field(name)` |
| Siblings | `next_sibling`, `previous_sibling`, `next_named_sibling`, `previous_named_sibling` |
| Search | `descendant(from, to)`, `named_descendant(from, to)`: the smallest node spanning a byte range |

### Queries

```crystal
query = TreeSitter::Query.new(json, <<-SCM)
  (pair key: (string) @key)
  ((string (string_content) @keyword) (#any-of? @keyword "if" "else"))
  SCM

query.each_capture(root, text) do |capture|
  capture.name             # "key"
  capture.node.range       # bytes
  capture.pattern          # index of the pattern that matched
end

query.each_match(root, text, 0...40) do |match|
  match["key"]             # first node captured as key
  match.nodes("key")       # every one, for quantified captures
end
```

`each_capture` yields captures in text order, which is what highlighting needs. `each_match` yields whole matches. Both take an optional byte range. The text for predicates comes from a `TreeSitter::Source` (`text(from, to)`); passing a `String` wraps it in a `StringSource`. Text held elsewhere, such as a line buffer, includes `Source` so a query never builds the whole document.

A query the grammar rejects raises `QueryError`, which carries its `kind` (`Syntax`, `NodeType`, `Field`, `Capture`, `Structure`, `Language`) and byte `offset`.

### Predicates

| Predicate | Passes when the capture's text |
| --- | --- |
| `#eq? @a "x"`, `#eq? @a @b` | Equals the string, or the other capture's text |
| `#match? @a "re"` (also `#vim-match?`) | Matches the regular expression (PCRE) |
| `#lua-match? @a "%u%w*"` | Matches the Lua pattern, translated to a regular expression |
| `#any-of? @a "x" "y"` | Is one of the strings |

Each predicate has a `not-` form (`#not-eq?`, …). A capture missing from the match passes. Directives (`#set!`, `#make-range!`), unknown predicates and a `#match?` whose expression does not compile are skipped, so the match is reported as if they were absent.

## Spec fixture

`require "treesitter/fixture"` (not loaded by `require "treesitter"`) adds `TreeSitter::Fixture`. It compiles the bundled JSON grammar (`fixtures/json`, MIT, from tree-sitter-json) with `cc` into a temporary directory on first use:

```crystal
json = TreeSitter::Fixture.language("json")
TreeSitter::Fixture.library("json")   # path of the compiled .so
TreeSitter::Fixture.clean             # removes the compiled libraries
```

## License

MIT. The bundled JSON grammar keeps its own MIT license in `fixtures/json/LICENSE`.
