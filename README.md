# treesitter

A minimal [tree-sitter](https://tree-sitter.github.io/) binding for Crystal, with bundled grammars and incremental syntax highlighting for [scribe](https://github.com/shpeckman/scribe) documents.

It parses text into syntax trees, runs queries over them (with the common predicates), and keeps a tree in step with a `Scribe::Document` as it is edited, serving highlight tokens line by line. It draws nothing: tokens are plain values for the host — a terminal UI such as [tui](https://github.com/shpeckman/tui), or anything else — to style.

It depends only on scribe, the standard library, and the tree-sitter runtime and grammars it builds from source.

## Requirements

- Crystal 1.21 or newer
- A C compiler, `ar` and `make`, to build the vendored tree-sitter runtime and grammars when the shard is installed

## Installation

```yaml
dependencies:
  treesitter:
    github: shpeckman/treesitter.cr
```

Then run `shards install` and `require "treesitter"`. Installing runs `make native`, which unpacks `vendor/tree-sitter-deps.tar.gz` and compiles the runtime and the grammars into `vendor/build/`.

## Quick start

`graphemes` is your `Scribe::Graphemes` (see scribe's README).

```crystal
require "treesitter"

document = Scribe::Document.new(graphemes, File.read("src/app.cr"), filter: Scribe::MultiLine.new)
syntax   = TreeSitter::Syntax.for(document, "src/app.cr")   # nil when no bundled language fits the path

if syntax
  syntax.tokens(document.buffer, 0)   # Array(Scribe::Highlighter::Token): start, count, kind ("keyword", "function.method", …)
  document.insert("x")                # the tree follows the edit
  syntax.root.has_error?              # reparsed on demand
end
```

## Languages

| Name      | Extensions     | Comment | Grammar                                                                          |
|-----------|----------------|---------|----------------------------------------------------------------------------------|
| `bash`    | `.sh`, `.bash` | `#`     | [tree-sitter-bash](https://github.com/tree-sitter/tree-sitter-bash)              |
| `c`       | `.c`, `.h`     | `//`    | [tree-sitter-c](https://github.com/tree-sitter/tree-sitter-c)                    |
| `crystal` | `.cr`          | `#`     | [tree-sitter-crystal](https://github.com/crystal-lang-tools/tree-sitter-crystal) |
| `json`    | `.json`        | —       | [tree-sitter-json](https://github.com/tree-sitter/tree-sitter-json)              |
| `python`  | `.py`, `.pyi`  | `#`     | [tree-sitter-python](https://github.com/tree-sitter/tree-sitter-python)          |

```crystal
TreeSitter.language("crystal")        # raises TreeSitter::Error for an unknown name
TreeSitter.language?("cobol")         # => nil
TreeSitter.language_for("x/main.c")   # by extension, or nil
TreeSitter.languages
```

A `Language` has a `name`, its `extensions`, a line `comment` prefix (for `Scribe::Document#comment`), and its `highlights` query, compiled on first use.

**Your own grammars.** Link the grammar's compiled `parser.c` (and `scanner.c`) into your program, bind its `tree_sitter_<name>` function, and register it. A registered language wins the extensions it lists:

```crystal
@[Link(ldflags: "#{__DIR__}/../grammars/toml/parser.o #{__DIR__}/../grammars/toml/scanner.o")]
lib LibToml
  fun tree_sitter_toml : LibTreeSitter::TSLanguage
end

TreeSitter.register(TreeSitter::Language.new("toml", LibToml.tree_sitter_toml, %w(.toml),
  comment: "#", highlights: File.read("grammars/toml/highlights.scm")))
```

**Precedence.** When several patterns capture the same node, the later pattern wins, as in current upstream queries and editors such as Neovim. A smaller node always wins over a larger one around it. `Language.new(…, precedence: TreeSitter::Precedence::First)` makes the earlier pattern win instead, for queries written that way; the bundled `json` query is one.

## Parsing

```crystal
json   = TreeSitter.language("json")
tree   = json.parse(%({"a": [1, null]}))
tree.to_s   # => "(document (object (pair key: (string (string_content)) value: (array (number) (null)))))"

parser = json.parser                       # reuse a parser for many parses
tree   = parser.parse(document.buffer)     # reads the buffer line by line, without copying it
```

`Parser#parse(text_or_buffer, old_tree)` reparses incrementally when given the previous tree after it has been told about the edits with `Tree#edit(change, buffer)` (call it from `Scribe::Listener#applied`, or `Buffer#on_change`). `old.changed_ranges(new)` lists the `Region`s (bytes and rows) whose syntax changed. `Tree#copy` makes an independent copy.

A `Node` is a light value. It has `type`, `start_byte`/`end_byte` (`bytes`), `start_point`/`end_point` (a `Scribe::Point` with the column in bytes), `named?`, `error?`, `missing?` and `has_error?`, plus navigation: `child(i)`, `named_child(i)`, `children`, `named_children`, `field("name")`, `parent` and `descendant(from_byte, to_byte, named: true)`. `text(source)` reads its text from the `String` or `Scribe::Buffer` it was parsed from, and `sexp` (or `to_s`) prints the subtree.

## Queries

```crystal
query = json.query(%|((pair key: (string (string_content) @key)) (#eq? @key "name"))|)
query.captures(tree.root, text)            # Array(TreeSitter::Capture): node, name, index, pattern
query.each_capture(tree.root, buffer, from_byte, to_byte) { |capture| }
query.each_match(tree.root, text) { |pattern, captures| }
```

A malformed query raises `TreeSitter::QueryError` with its `kind` and a line and column in the message. These predicates are applied: `#eq?` and `#not-eq?` (against a string or another capture), `#match?` and `#not-match?` (a regular expression), and `#any-of?` and `#not-any-of?`. Others, such as `#set!`, are ignored. A query keeps one cursor, so do not run a query again from inside its own block.

## Highlighting a document

`TreeSitter::Syntax.new(document, language)` (or `Syntax.for(document, path)`) parses the document, listens to it, and implements `Scribe::TokenSource`:

- Each change is applied to the tree as it lands. The tree is reparsed once, lazily, the next time tokens or the tree are asked for, so a burst of typing costs one reparse per frame.
- Tokens are cached per line. An edit forgets the lines it touched, and a reparse forgets the lines whose syntax changed, such as everything after a newly opened block comment.
- A token's `kind` is the capture name, such as `keyword.return` or `string.special.key`. Columns count clusters, like every other scribe token. Captures whose names start with `_` are skipped.
- `tree`, `root` and `node_at(offset, named: true)` give the current syntax tree. `close` stops listening.

A different query, for example your own `highlights.scm`, can be passed as the third argument.

## Using it with tui

`tui`'s `Editor` takes any `Scribe::TokenSource` and styles a token with `editor.<kind>`, through every prefix of a dotted name: a `keyword.return` token gets `editor.keyword` merged with `editor.keyword.return`. Stock styles cover the common first segments (`keyword`, `string`, `comment`, `number`, `type`, `module`, `function`, `constant`, `boolean`, `property`, `label`, `escape`, `operator`); a theme can add or refine any capture.

```crystal
def highlight(editor : TUI::Editor, path : String) : TreeSitter::Syntax?
  syntax = TreeSitter::Syntax.for(editor.document, path) || return nil
  editor.token_source = syntax
  editor.comment      = syntax.language.comment
  syntax
end
```

## Development

```sh
make spec
```

`make spec` builds the native parts if needed and runs the specs. `make clean` removes them. The highlight queries are compiled into the program from `queries/` when it is built.

**Vendored files.** `vendor/tree-sitter-deps.tar.gz` holds the tree-sitter 0.28 runtime and the five grammars' generated parsers, as vendored by [ts-edit](https://github.com/shpeckman/ts-edit). Each `queries/<language>/highlights.scm` is copied unchanged from its grammar's repository, at the commit whose `src/grammar.json` matches the vendored grammar, and sits next to that grammar's `LICENSE` (all MIT):

| Language | Query commit                               |
|----------|--------------------------------------------|
| bash     | `a06c2e4415e9bc0346c6b86d401879ffb44058f7` |
| c        | `b780e47fc780ddc8da13afa35a3f4ed5c157823d` |
| crystal  | `f5530b7608392aaf219a0c76cfa668b1086677ec` |
| json     | `254c42a6476413b776221e03982ac8ae159eeb72` |
| python   | `26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64` |

## License

MIT. The vendored tree-sitter runtime and grammars keep their own MIT licences.
