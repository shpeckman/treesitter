# AGENTS.md

Orientation for AI agents working on this repository.

## What this is

`treesitter` (repository `treesitter.cr`, module `TreeSitter`) is a minimal tree-sitter binding for Crystal. It bundles five grammars (bash, c, crystal, json, python) with their upstream highlight queries, runs queries with the common predicates, and keeps a syntax tree in step with a `scribe` document so it can serve highlight tokens through `Scribe::TokenSource`. It depends only on `scribe` and the standard library, and must never depend on a UI shard; hosts such as `tui` wire it up themselves (the README shows how).

## Layout

- `src/treesitter.cr` — requires every file in load order.
- `src/treesitter/lib.cr` — `LibTreeSitter`: the C API subset in use, linked against `vendor/build/libgrammars.a` and `libtree-sitter.a` through `@[Link(ldflags:)]`.
- `src/treesitter/query.cr` — `Error`, `QueryError`, `Capture`, and `Query`: compiling, capture names, predicates compiled once per pattern, and `each_match`/`each_capture`/`captures` over a byte range with one reused cursor.
- `src/treesitter/tree.cr` — `Region`, the `Node` value (with its tree, so the tree outlives it), `Tree` (edit from a `Scribe::Change`, copy, changed ranges), and point conversion.
- `src/treesitter/parser.cr` — `Parser`: parses a `String`, or a `Scribe::Buffer` through a `TSInput` read callback over `Buffer#chunk`.
- `src/treesitter/language.cr` — `Precedence`, `Language`, the registry of built-in languages (queries embedded at compile time with `read_file`), `register`, `language`, `language?`, `language_for`.
- `src/treesitter/syntax.cr` — `Syntax`: the `Scribe::Listener` and `Scribe::TokenSource` that edits the tree as changes land, reparses lazily, invalidates cached lines, and paints captures into per-line tokens.
- `queries/<language>/` — upstream `highlights.scm` and the grammar's `LICENSE`, unchanged.
- `vendor/tree-sitter-deps.tar.gz` — the tree-sitter runtime and the generated grammars (from `ts-edit`). `vendor/deps/` and `vendor/build/` are build products.
- `Makefile` — `native` (run by the shard's `postinstall`), `spec`, `clean`.
- `spec/` — one file per area; `spec/spec_helper.cr` defines a standard-library `Graphemes` (`Plain`) and the `document`, `kinds` and `fresh_tokens` helpers.

## Commands

- `make native` — build the runtime and grammars (needed once before anything else).
- `make spec` or `crystal spec` — run the suite.
- `crystal build --no-codegen src/treesitter.cr` — fast compile check.

## Rules

- Byte offsets and points come from scribe: `Buffer#byte_offset`, `line_byte`, `byte_text`, `chunk`, and `Change#start_point`/`old_end_point`/`new_end_point` with `Scribe::Units::Bytes`. Never compute them by hand.
- `Syntax#applied` only edits the tree and forgets touched lines; parsing happens in `refresh`, on demand. Keep it that way so a transaction or a burst of typing costs one reparse.
- Token columns are clusters, built from `Line#marks`; captures are painted widest node first, then by pattern in the language's `Precedence`, so the smallest node and the winning pattern end up on top.
- A new grammar means: add its sources to the vendored archive, its objects to `GRAMMAR_OBJS` (they are archived into `libgrammars.a`, which `lib.cr` links), its `tree_sitter_<name>` function to `LibTreeSitter`, an entry in the registry, its query and licence under `queries/`, a row in the README's language and commit tables, and a spec that its query compiles.
- Vendored queries are copied unchanged from the commit matching the vendored `grammar.json`; record the commit in the README.
- A new predicate is a `Query::Test` member, an entry in `TESTS`, a branch in `check`, and a spec in `spec/query_spec.cr`.
- Free what tree-sitter allocates for us (`ts_node_string`, `ts_tree_get_changed_ranges`) with `LibC.free`; trees, parsers, queries and cursors are freed in `finalize`.

## Code standards

- Compiler-friendly, performance-focused, idiomatic and data-driven.
- The usage-facing API must be ergonomic.
- Avoid shotgun surgery: one change should land in one place.
- No comments, except every file starts with a comment containing its own path (e.g. `# src/treesitter.cr`).
- Never use `out` as an identifier.
- Never edit the `version` field in `shard.yml`.
- Keep `README.md` (usage and public API) and this file in sync with the code.
