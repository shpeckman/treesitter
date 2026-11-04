# treesitter

Crystal bindings to the [Tree-sitter](https://tree-sitter.github.io) C library: grammars loaded from shared libraries at run time, incremental parsing from a string or a chunked reader, syntax nodes, and queries with the common predicates.

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

`Language.load(name)` finds and loads a grammar from `Language.directories`. Lookup checks each directory in order for `libtree-sitter-<name>.so` and `<name>.so`; `Language.find(name)` returns the matching path or `nil`. The default directories are `~/.local/lib`, `/usr/local/lib`, `/usr/local/lib64`, `/usr/lib`, and `/usr/lib64`. Replace, append to, or prepend to the array to configure lookup:

```crystal
TreeSitter::Language.directories.unshift("/opt/tree-sitter")
json = TreeSitter::Language.load("json")
```

`Language.load(name)` raises `TreeSitter::Error` when no library is found. `Language.load(path, name, symbol = "tree_sitter_<name>")` opens an explicit grammar library and calls its entry function; dashes in the name become underscores in the default symbol. Both forms raise `TreeSitter::Error` when the library or symbol is missing, or when the grammar's ABI is outside `Language::MIN_ABI..Language::MAX_ABI` (13 to 15). A grammar linked into the program can be wrapped directly: `Language.new(tree_sitter_json(), "json")`. Loaded libraries stay open for the life of the process.

### Parsing

| Call                                                                 | Parses                                                                                                                                                                |
|----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `parse(text, old_tree = nil)`                                        | A string                                                                                                                                                              |
| `parse(old_tree = nil) { \|byte\| bytes }`                           | Text read in chunks: the block gets a byte offset and returns the bytes from there, of any length, and an empty slice at the end                                      |
| `parse(old_tree, cancel: ->(byte : Int32) { … }) { \|byte\| bytes }` | Chunks as above, asking `cancel` with the byte reached as it goes; returns `nil` once it answers `true` (a time budget, a newer edit), and the next parse starts over |
| `parse(text, old_tree = nil, timeout: 50.milliseconds)`              | A string within a time budget; returns `nil` once it runs out, so a grammar whose error recovery explodes on some input cannot take unbounded time or memory |

A chunk must stay unchanged until the next call; the parser keeps the last one alive. Raises `Error` when the parse does not finish.

To reparse after a change, describe it with `Tree#edit` and pass the old tree:

```crystal
tree = parser.parse("[1, 2]")
tree.edit(TreeSitter::Edit.new(start_byte: 5, old_end_byte: 5, new_end_byte: 8,
  start_point: TreeSitter::Point.new(0, 5), old_end_point: TreeSitter::Point.new(0, 5),
  new_end_point: TreeSitter::Point.new(0, 8)))
tree = parser.parse("[1, 2, 3]", tree)
```

`new_tree.changed_regions(old_tree)` lists the `Region`s (bytes and points) whose syntax differs between the edited
old tree and the new one; text edited inside an unchanged structure is not among them.

`parser.included_regions = regions` limits the following parses to those regions of the text, in order and not
overlapping, for a language embedded in another one (a `<script>` in HTML, a fenced block in Markdown); an empty array
parses the whole text again. `Node#region` gives a node's region.

```crystal
parser.included_regions = [script.region]
inner = parser.parse(text)
```

Offsets are bytes into UTF-8 text. A `Point` is a zero-based row and a byte column. `Tree#copy` makes an independent copy, cheap to make, for use on another fiber.

### Nodes

`Node` is a value tied to its `Tree`, and it keeps the tree alive. Every navigation method returns `nil` where there is no node.

| Group    | Methods                                                                                                     |
|----------|-------------------------------------------------------------------------------------------------------------|
| Identity | `type`, `named?`, `extra?`, `==`                                                                            |
| Position | `start_byte`, `end_byte`, `range`, `start_point`, `end_point`                                               |
| Errors   | `error?` (an `ERROR` node), `missing?` (inserted by recovery, zero width), `has_error?` (either one inside), `error_bytes` (bytes in `ERROR` nodes plus one per missing node) |
| Tree     | `parent`, `child(i)`, `child_count`, `named_child(i)`, `named_child_count`, `field(name)`                   |
| Siblings | `next_sibling`, `previous_sibling`, `next_named_sibling`, `previous_named_sibling`                          |
| Search   | `descendant(from, to)`, `named_descendant(from, to)`: the smallest node spanning a byte range               |

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

| Predicate                              | Passes when the capture's text                              |
|----------------------------------------|-------------------------------------------------------------|
| `#eq? @a "x"`, `#eq? @a @b`            | Equals the string, or the other capture's text              |
| `#match? @a "re"` (also `#vim-match?`) | Matches the regular expression (PCRE)                       |
| `#lua-match? @a "%u%w*"`               | Matches the Lua pattern, translated to a regular expression |
| `#any-of? @a "x" "y"`                  | Is one of the strings                                       |

Each predicate has a `not-` form (`#not-eq?`, …). A capture missing from the match passes. Directives (`#set!`, `#make-range!`), unknown predicates and a `#match?` whose expression does not compile are skipped, so the match is reported as if they were absent.

`query.properties(pattern)` holds the `#set!` directives of a pattern as key → value (`""` when a key is set without
one): `(#set! injection.language "lua")` gives `{"injection.language" => "lua"}`. Read it with `match.pattern` or
`capture.pattern`.

## Language detection

`require "treesitter/detect"` (not loaded by `require "treesitter"`) adds `TreeSitter::Detector`. It guesses the language of text that has no file name, such as a pasted snippet:

1. An [rlcd](https://github.com/shpeckman/rlcd) model, trained with a proper scoring rule, ranks the languages with calibrated probabilities. It hashes words, symbol runs and character 2–5-grams of the text.
2. Optionally, the parse check (opt-in, `checked` > 0): the `checked` most probable languages are parsed with their grammars (`Language.find`). Each one's probability is multiplied by `exp(-penalty * error_ratio)`, where `error_ratio` is the share of the text that falls in `ERROR` nodes, with one byte counted per missing node. The checked candidates then share out their original total again. A language without a loadable grammar, or whose parse runs past `timeout`, is not reweighted.

The parse check is off by default. It gains little over the model (measurements below), costs about 2.5 times the time, depends on which grammars are installed, and runs each grammar's C code on the text. Some grammars misbehave on unexpected input: Julia's error recovery grew one parse past 3 GB, which `timeout` stops, and Perl's external scanner looped forever, which no in-process timeout can interrupt because tree-sitter only checks for cancellation between parser steps. Enable it only for grammars you trust, or run detection in a separate process you can kill.

Labels are grammar names, so the detected name goes straight to `Language.load`.

```crystal
require "treesitter/detect"

detector = TreeSitter::Detector.train({
  "json"   => json_snippets,
  "python" => python_snippets,
  "ruby"   => ruby_snippets,
}, epochs: 30)
detector.save("languages.rlcd", precision: RLCD::Precision::I8)

detector  = TreeSitter::Detector.load("languages.rlcd")
detection = detector.detect("def greet(name):\n    print(name)\n")
detection.language                 # => "python", or nil below the threshold
detection.probability              # => 0.97
detection.candidates               # => [Candidate("python", 0.97, nil), Candidate("ruby", 0.02, nil), ...]
detection.language.try { |name| TreeSitter::Language.load(name) }
```

| Setting                  | Default | Meaning                                                                                       |
|--------------------------|---------|-----------------------------------------------------------------------------------------------|
| `checked`                | 0       | How many of the most probable languages get the parse check; 0 keeps the model's probabilities |
| `penalty`                | 1.0     | How strongly parse errors count                                                                |
| `threshold`              | 0.5     | Probability `Detection#language` needs; `detect(text, threshold:)` overrides it per call      |
| `timeout`                | 50 ms   | Time budget of one candidate's parse check; a candidate that runs out is not reweighted         |

`Detector.train(samples, dim: 4096, seed: 42, hidden: 0, epochs: 60, lr: 0.01, validation: 0.15, calibration: nil, checkpoint: nil, rng:)` takes grammar name → snippets, for at least two languages. It trains a linear head (or a `hidden` layer) with the log score. A temperature calibrates the result, fitted on `calibration:` (grammar name → snippets kept apart from the training samples) when given, otherwise on the `validation` share of each language's snippets. `Detector.error_ratio(root, text)` is the share of the text a parse could not fit, the measure the parse check uses. `seed` also fixes each epoch's shuffle order. With `checkpoint:` (a path), training saves its state there after every epoch, atomically; a later call that finds the file continues after its last completed epoch and reaches the weights of an uninterrupted run, and raises `ArgumentError` when the file belongs to another run (different labels, featurizer, hidden layer or seed) or is already past `epochs`. `save` writes JSON for a `.json` path and the compact rlcd binary otherwise, with `precision` `F64`, `F32` or `I8`. `Detector.load` detects the format and raises `RLCD::FormatError` for a malformed file. `detector.model` is the `RLCD::Model`, and it carries the optimizer state, so training can resume with `RLCD::Trainer`. A detector reuses one parser, so give each fiber its own.

Measured on this machine: 1500 chunks of 25 lines per language for C, JavaScript, JSON, Python, Ruby and Rust, with 8-line chunks of other files held out. Detection was 96.0% accurate with ECE 0.020 without the parse check (0.5 ms per snippet), and 96.1% with ECE 0.017 with it (1.3 ms). The I8 model, optimizer state included, is 221 KB.

## Spec fixture

`require "treesitter/fixture"` (not loaded by `require "treesitter"`) adds `TreeSitter::Fixture`. It compiles the bundled JSON grammar (`fixtures/json`, MIT, from tree-sitter-json) with `cc` into a temporary directory on first use:

```crystal
json = TreeSitter::Fixture.language("json")
TreeSitter::Fixture.library("json")   # path of the compiled .so
TreeSitter::Fixture.clean             # removes the compiled libraries
```

## Man pages

`man/` holds two gzipped man pages generated from this README and the API doc comments: `treesitter(7cr)` for the overview and `treesitter(3cr)` for the API, with one section per type. Read them from the installed shard:

```sh
man -M lib/treesitter/man 3cr treesitter
man -l lib/treesitter/man/man7/treesitter.7cr.gz
```

## License

MIT. The bundled JSON grammar keeps its own MIT license in `fixtures/json/LICENSE`.
