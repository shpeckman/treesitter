# AGENTS.md

How to work on `treesitter`: Crystal bindings to the Tree-sitter C library (`TreeSitter`). Usage and the public API live in `README.md`.

## Repository layout

```
shard.yml                    no shard deps; crystal >= 1.21.0; libtree-sitter >= 0.25 (pkg-config)
.github/workflows/ci.yml     CI: builds libtree-sitter v0.25.2 from source, then crystal spec
src/treesitter.cr            entry: requires src/tree_sitter/* in dependency order; documents module TreeSitter
src/fixture.cr               `require "treesitter/fixture"`: TreeSitter::Fixture (compiles fixtures/<name>/parser.c with cc into a temp .so)
src/tree_sitter/
  lib.cr                     LibTreeSitter: @[Link("tree-sitter")], the C structs (Point, Range, InputEdit, Node, Input, ParseState, ParseOptions, QueryCapture, QueryMatch, QueryPredicateStep) and the functions used
  error.cr                   Error; QueryError (offset, Kind, line in the message)
  values.cr                  Point (row, byte column), Edit (bytes + points, to_lib), Region (bytes + points, to_lib, of)
  language.cr                Language: wraps a TSLanguage pointer (ABI check MIN_ABI..MAX_ABI), Language.load (dlopen + dlsym, never closed)
  tree.cr                    Tree: root, edit, changed_regions (ts_tree_get_changed_ranges, freed with LibC.free), copy; ts_tree_delete in finalize
  node.cr                    Node: value over LibTreeSitter::Node + its Tree (region for included regions); navigation returns nil for null nodes
  parser.cr                  Parser: parse(string), parse { |byte| bytes } through a TSInput read callback (Reader boxed as payload), parse(old, cancel:) through ts_parser_parse_with_options (reset after a cancel), included_regions=
  source.cr                  Source (text(from, to) in bytes), StringSource
  predicate.cr               Predicate: TESTS table (name → {Test, negated, lua}), LUA_CLASSES, list (parse steps per pattern), properties (#set! groups), lua translation, satisfied?
  query.cr                   Capture, Match records; Query: compile, capture_names, properties (per pattern), each_capture (next_capture, verdict cached per match id), each_match, byte ranges
fixtures/json/               tree-sitter-json parser.c + tree_sitter/*.h (ABI 14, MIT, LICENSE kept), only for specs
spec/
  spec_helper.cr             JSON_GRAMMAR from the fixture; types(node) helper
  tree_sitter_spec.cr        Language, Parser (string, reader, incremental, changed regions, included regions, cancel, errors, descendants), Query (captures, ranges, predicates, properties, errors, Lua)
```

## Commands

```sh
shards install
crystal spec                     # needs libtree-sitter >= 0.25 and cc
crystal spec spec/tree_sitter_spec.cr:42
```

`crystal tool format` is not used: the code keeps the aligned-column style of the Asekii shards, which the formatter strips.

## Architecture notes

- **Binding surface.** `lib.cr` declares only the functions the wrappers call. A new wrapper adds its function there, with the exact C layout from `tree_sitter/api.h` of 0.25: `TSInput` has the `decode` field and `ts_language_abi_version` exists only from 0.25, which is why older libraries are not supported.
- **Lifetimes.**
  - `Tree`, `Parser` and `Query` own their C objects and free them in `finalize`.
  - `Node` holds its `Tree`, so a node never outlives the tree's memory.
  - `Language.load` never `dlclose`s, because trees and queries keep pointers into the grammar's tables.
- **Reading input.** `Parser#parse(&)` hands C a non-closure callback; the block lives in a `Reader` boxed as the payload. `Reader` keeps the last chunk in `@held` so the GC cannot free the bytes C is still reading. The `cancel:` overload boxes its proc the same way as the `TSParseOptions` payload, and calls `ts_parser_reset` after a cancelled parse, so the next parse never resumes a stale one.
- **Predicates are data.**
  - `#set!` directives are not tests: `Predicate.properties` collects them per pattern into `Query#properties`.
  - `Predicate::TESTS` maps each name to `{Test, negated, lua}`; a new spelling is a new row.
  - Predicates are parsed once per pattern at `Query.new`, with regexes compiled there.
  - `each_capture` evaluates a match's predicates once per match id, not once per capture.
- **Ranges.** `each_capture`/`each_match` take an exclusive or inclusive `Range(Int32, Int32)` of bytes and pass it to `ts_query_cursor_set_byte_range` (captures intersecting it).

## Naming conventions

1. Paths mirror namespaces, with one primary type per file: `src/tree_sitter/<type>.cr` holds `TreeSitter::<Type>`. Small records that belong to a file's type live in it (`Capture` and `Match` in `query.cr`, `Edit` with `Point` in `values.cr`).
2. Public API uses full words: `previous_sibling` (the C API's `prev`), `named_descendant`.
3. Bools end in `?`.
4. Enums nest in their owner (`QueryError::Kind`, `Predicate::Test`).

## Git workflow

- Repository: `github.com/shpeckman/treesitter`. It is checked out in `asekii-lib/vendor/`; the workspace is not a repository.
- Dependency order: treesitter → asekii-editor. Push and tag it before asekii-editor.
- One logical change per commit.
- Releases: the maintainer bumps `version` in `shard.yml`, tags `v<version>` and pushes the tag. Agents never bump `version` or tag. They commit, push, open and merge pull requests and rerun CI only when the user asks, following the Git and GitHub flow in the workspace's `AGENTS.md` (`asekii-lib/AGENTS.md`).
- `shard.lock` stays untracked (`.gitignore`).

## Code standards

- Write compiler-friendly, performance-focused, idiomatic Crystal.
- Use data-driven design: tables (constants, enums, records) instead of branching code.
- Comments:
  - Every file starts with a comment holding its path, e.g. `# src/tree_sitter/query.cr`, followed by a blank line, so `crystal docs` never takes it as the doc of the first declaration.
  - Public types, modules, enums, records, API constants and public methods get doc comments for `crystal docs`: Markdown, directly above the declaration, one or two sentences that say what it does, returns or means (units, ranges, side effects). Refer to other API in backticks (`Tree#edit`) so the doc tool links it.
  - Private code gets a plain comment only where the reason is not obvious from the code. Use comments sparingly: no section banners, no commented-out code, no change notes.
- Keep the user-facing API ergonomic.
- Prevent shotgun surgery: one concept, one place.
- Match the surrounding style: aligned assignments, explicit return types, `@[AlwaysInline]` on hot accessors.
- Do not add functionality nobody asked for.
- Deliver complete files: no stubs, no placeholders.
- Do not change `version` in `shard.yml`.
- Keep `README.md` and `AGENTS.md` in sync with the code.
- Write everything in English.
