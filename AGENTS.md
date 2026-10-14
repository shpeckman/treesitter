# AGENTS.md

Orientation for AI agents working on this repository.

## What this is

`treesitter` is a minimal [tree-sitter](https://tree-sitter.github.io/) binding for Crystal with bundled grammars, and it is where syntax highlighting lives for the scribe family. `scribe` defines `Scribe::Token` and the `TokenSource` and `Tokenizer` interfaces and produces no tokens itself; the two classes here implement them. It draws nothing: tokens are plain values for a host such as the `tui` shard to style.

It depends only on `scribe`, the standard library, and the vendored tree-sitter runtime and grammars it builds from source.

## Layout

- `src/treesitter.cr` — requires every file in load order.
- `src/treesitter/lib.cr` — the `LibTreeSitter` bindings and the `tree_sitter_<name>` functions of the bundled grammars, linked from `vendor/build/`.
- `src/treesitter/parser.cr`, `tree.cr` — `Parser` (parses a `String` or a `Scribe::Buffer`, incrementally when given the previous tree), `Tree`, `Node` and `Region`. `Tree#edit` takes a `Scribe::Change` and the buffer it landed in.
- `src/treesitter/query.cr` — `Query`, `Capture` and the applied predicates (`#eq?`, `#not-eq?`, `#match?`, `#not-match?`, `#any-of?`, `#not-any-of?`); others are ignored. One cursor per query, so never run a query from inside its own block.
- `src/treesitter/language.cr` — `Language`, the `Precedence` rule, the registry (`TreeSitter.language`, `language?`, `language_for`, `register`, `languages`), and the `highlights` macro that compiles `queries/<name>/highlights.scm` into the program. A language also holds optional `injections` and `locals` query sources, empty for the bundled grammars and settable at runtime; each compiles on first use and is dropped when reassigned.
- `src/treesitter/injection.cr` — `Injection`: one injected region, parsed with `Parser#included_ranges=` so the nested tree reports host-absolute byte offsets and its tokens land on host columns. `Injection.collect` runs a language's injection query and reads the nested language from a `#set!` property or an `@injection.language` capture.
- `src/treesitter/locals.cr` — `Locals`: the definitions, references and scopes a `locals.scm` query finds, and `refine`, which turns a token over a resolved reference into `variable`.
- `src/treesitter/painter.cr` — `Painter`: turns the captures overlapping one line into runs of `Scribe::Token`. Smaller nodes win over larger ones; ties go to the later pattern, or the earlier one under `Precedence::First`. This is the only place that resolves overlapping captures.
- `src/treesitter/syntax.cr` — `Syntax`: a `Scribe::Listener` and `Scribe::TokenSource` over one document, plus `fold_ranges`, which walks the tree for multi-line named nodes and needs no query file. Each change is applied to the tree as it lands; the reparse is lazy, on the next request for tokens or the tree. Tokens are cached per line and dropped for the lines an edit touched and the lines `changed_ranges` reports.
- `src/treesitter/tokenizer.cr` — `Tokenizer`: a `Scribe::Tokenizer` for standalone text. Builds a throw-away `Scribe::Buffer`, parses it and paints every line. Keeps no state between calls.
- `queries/<language>/highlights.scm` — copied unchanged from each grammar's repository, with its `LICENSE`. The commit per language is in the README.
- `vendor/tree-sitter-deps.tar.gz` — the runtime and the generated parsers; `make native` unpacks and builds them into `vendor/build/`.
- `spec/` — one file per area. `spec/spec_helper.cr` defines a standard-library `Graphemes` (`Plain`) and the `document`, `kinds` and `fresh_tokens` helpers.

## Commands

- `make spec` — build the native parts if needed, then run the suite.
- `make native` — build the vendored runtime and grammars into `vendor/build/`.
- `make clean` — remove them.
- `crystal build --no-codegen src/treesitter.cr` — fast compile check.

## Rules

- Token columns count grapheme clusters, never bytes: convert through the `Scribe::Buffer` the text was parsed from. Byte offsets from a `Node` are mapped with `Line#marks`, as `Painter` does.
- New token behaviour goes in `Painter`, so `Syntax` and `Tokenizer` cannot disagree. Never duplicate capture resolution in either of them.
- An injected region is parsed against the host buffer with included ranges, never by extracting its text: that is what keeps the nested offsets absolute. `Syntax#paint` applies locals first and injections second, so an injected region's own tokens win over both.
- Injections and locals are recollected on reparse, in `refresh`. Anything else derived from the tree is invalidated there too.
- `Syntax` reparses lazily and exactly once per burst: `applied` only marks the tree stale, and `refresh` is what reparses. Keep it that way, so a burst of typing costs one reparse.
- A capture whose name starts with `_` is not a token.
- Adding a bundled language means a grammar in `vendor/tree-sitter-deps.tar.gz`, its `tree_sitter_<name>` binding in `lib.cr`, a `queries/<name>/highlights.scm` with its `LICENSE`, an entry in the `@@languages` table, and rows in the README's language and query-commit tables.
- Never bind a tree-sitter function that is not used, and never reach for the C API from outside `lib.cr`.

## Code standards

- Compiler-friendly, performance-focused, idiomatic and data-driven.
- The usage-facing API must be ergonomic.
- Avoid shotgun surgery: one change should land in one place.
- No comments, except every file starts with a comment containing its own path (e.g. `# src/treesitter/syntax.cr`).
- Never use `out` as an identifier.
- Never edit the `version` field in `shard.yml`.
- Keep `README.md` (usage and public API) and this file in sync with the code.
