# AGENTS.md

How to work on `treesitter`: Crystal bindings to the Tree-sitter C library (`TreeSitter`). Usage and the public API live in `README.md`.

## Repository layout

```
shard.yml                    dependency rlcd (github shpeckman/rlcd, branch main); crystal >= 1.21.0; libtree-sitter >= 0.25 (pkg-config)
.github/workflows/ci.yml     CI: builds libtree-sitter v0.25.2 from source, then crystal spec
src/treesitter.cr            entry: requires src/tree_sitter/* in dependency order; documents module TreeSitter
src/fixture.cr               `require "treesitter/fixture"`: TreeSitter::Fixture (compiles fixtures/<name>/parser.c with cc into a temp .so)
src/detect.cr                `require "treesitter/detect"`: requires rlcd, the bindings and tree_sitter/detector.cr
src/tree_sitter/
  lib.cr                     LibTreeSitter: @[Link("tree-sitter")], the C structs (Point, Range, InputEdit, Node, Input, ParseState, ParseOptions, QueryCapture, QueryMatch, QueryPredicateStep) and the functions used
  error.cr                   Error; QueryError (offset, Kind, line in the message)
  values.cr                  Point (row, byte column), Edit (bytes + points, to_lib), Region (bytes + points, to_lib, of)
  language.cr                Language: wraps a TSLanguage pointer (ABI check MIN_ABI..MAX_ABI), directories/find for .so lookup, Language.load (autodetect or dlopen + dlsym, never closed)
  tree.cr                    Tree: root, edit, changed_regions (ts_tree_get_changed_ranges, freed with LibC.free), copy; ts_tree_delete in finalize
  node.cr                    Node: value over LibTreeSitter::Node + its Tree (region for included regions); navigation returns nil for null nodes; error_bytes (ERROR spans + MISSING_BYTES per missing node)
  parser.cr                  Parser: parse(string), parse { |byte| bytes } through a TSInput read callback (Reader boxed as payload), parse(old, cancel:) through ts_parser_parse_with_options (reset after a cancel), parse(string, timeout:) on top of it, included_regions=
  source.cr                  Source (text(from, to) in bytes), StringSource
  predicate.cr               Predicate: TESTS table (name → {Test, negated, lua}), LUA_CLASSES, list (parse steps per pattern), properties (#set! groups), lua translation, satisfied?
  query.cr                   Capture, Match records; Query: compile, capture_names, properties (per pattern), each_capture (next_capture, verdict cached per match id), each_match, byte ranges
  detector.cr                Detector (only through src/detect.cr): Candidate, Detection records; default (models/languages.rlcd embedded with read_file); train (RLCD::Model over code features, stratified validation split or `calibration:` set, temperature, `checkpoint:` path saved every epoch and resumed through RLCD::Checkpoint), load/save, error_ratio, detect (model ranking, parse check of the top `checked` grammars)
models/                      committed output of scripts/model.cr: languages.rlcd (I8, weights only, embedded by Detector.default), REPORT.md (data, metrics, gate)
scripts/
  languages.yml              manifest: the 26 grammars of the model (name, repo, pinned revision, license, family, corpus/examples dirs, github language, extensions)
  sources.yml                real-code repositories written by `discover` (repo, pinned revision, permissive license, GitHub language, stars); reviewed before building
  model.cr                   pipeline CLI: discover, fetch, verify (worker), build (systemd memory scope → collect or reuse cache → verify in worker → split → memory check → train with checkpoint → evaluate I8 model → gate → models/)
  model/manifest.cr          Grammar (YAML row), Extensions (file name/extension → grammar, shared entries dropped), Manifest.load
  model/sources.cr           Source (YAML row), Sources.discover (gh search API, PERMISSIVE licenses, git ls-remote pins), load/write
  model/fetch.cr             sparse shallow checkouts at pinned revisions, WORKERS in parallel, VENDORED dirs excluded
  model/corpus_file.cr       tree-sitter test corpus parser (port of cli/src/test.rs v0.25.2: suffixes, longest divider, :error/:skip/:language)
  model/collect.cr           Collector: corpus cases, examples and real files → windows, license headers stripped, generated files skipped, deduplicated by 64-bit hash, kept in a per-language reservoir of `budget` candidates, verified through a Verifier (MAX_ERROR per kind) in `samples`; Sample, Tally (JSON::Serializable); SETTINGS for the cache stamp
  model/verify.cr            Verifier: worker process (`build/model verify`, JSON lines) parses candidates within PARSE_TIMEOUT; the build waits DEADLINE per candidate and kills and restarts a hung or crashed worker; Verdict; serve (worker side)
  model/cache.cr             Cache: build/samples.jsonl (header with stamp and tallies, one sample per line), SHA-256 stamp, atomic write
  model/split.cr             Sets: train/calibration/test split by group (corpus case, example file, source repo), GROUP_CAP, per-language cap, CAL_CAP, TEST_CAP, MIN_TRAIN/MIN_TEST; SETTINGS for the checkpoint stamp
  model/evaluation.cr        Outcome, Metrics; run (model only, the default; the parse check is not run in-process), GATE table (ECE < 3%, family accuracy ≥ 80% on 6–15 and ≥ 90% on 16+ lines), Markdown report
build/                       gitignored: fetched repositories, sources, compiled pipeline, samples.jsonl cache, checkpoint.rlcd (+ .stamp), full model with optimizer state, REPORT.md of the last build
man/                         generated by `docv gen-cr`, committed: man7/treesitter.7cr (README), man3/<Type>.3cr (doc comments)
fixtures/json/               tree-sitter-json parser.c + tree_sitter/*.h (ABI 14, MIT, LICENSE kept), only for specs
spec/
  spec_helper.cr             JSON_GRAMMAR from the fixture; types(node) helper
  tree_sitter_spec.cr        Language (load, directory lookup, ABI, errors), Parser (string, reader, incremental, changed regions, included regions, cancel, errors, descendants), Query (captures, ranges, predicates, properties, errors, Lua)
  detector_spec.cr           Detector: one model trained on generated json/ruby/python snippets; detection, ranking, parse check (fixture json grammar via Language.directories), checked = 0, threshold, save/load, calibration set, training errors
```

## Commands

```sh
shards install
crystal spec                     # needs libtree-sitter >= 0.25 and cc
crystal spec spec/tree_sitter_spec.cr:42
docv gen-cr                                             # rewrite man/ after doc comment or README changes
crystal build --threads 2 --release -o build/model scripts/model.cr
build/model discover [--repos 12]                       # GitHub search → scripts/sources.yml (review it)
build/model fetch                                       # sparse checkouts into build/repos and build/sources
build/model build [--dim 4096] [--epochs 15] [--cap 1000] [--memory 4096]   # writes models/ only when the gate passes
docv TreeSitter::Node                                   # view a page (finds man/ of the project around the current directory)
for page in man/man*/*; do groff -man -t -ww -z "$page"; done   # roff warnings
```

`crystal tool format` is not used: the code keeps the aligned-column style of the Asekii shards, which the formatter strips.

## Architecture notes

- **Binding surface.** `lib.cr` declares only the functions the wrappers call. A new wrapper adds its function there, with the exact C layout from `tree_sitter/api.h` of 0.25: `TSInput` has the `decode` field and `ts_language_abi_version` exists only from 0.25, which is why older libraries are not supported.
- **Grammar lookup.** `Language.directories` is an ordered, configurable array of non-recursive search paths. `Language.find` checks `libtree-sitter-<name>.so` then `<name>.so` in each directory; `Language.load(name)` uses the first match.
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
- **Language detection.**
  - `Detector` lives outside `src/treesitter.cr`, so `require "treesitter"` never compiles rlcd. The dependency is still installed for every user.
  - Labels are grammar names; `Language.find` is the only lookup, so `Language.directories` configures which candidates get the parse check. Grammars are cached per detector, a failed load as `nil`.
  - The parse check reweights only the top `checked` candidates and keeps their total probability, so the other candidates' probabilities stay as the model gave them.
  - `penalty` 1.0 was chosen by measurement: on mid-file fragments the right grammar often has errors too, and 4.0 lowered accuracy (96.0% to 95.1%) while 1.0 raised it slightly (96.1%) and improved ECE.
  - The parse check is opt-in (`checked` defaults to 0). It gained little over the model (96.0% → 96.1% locally, 77.5% → 78.9% on the corpus build), costs ~2.5× the time, depends on the installed grammars, and runs grammar C code on user text. Keep the default at 0.
  - `checked`, `penalty`, `threshold` and `timeout` are runtime settings, not saved with the model.
  - Grammars are untrusted code. The Julia grammar's error recovery grew one parse past 3 GB on a real-code window; `Parser#parse(text, timeout:)` stops that, because the cancel callback runs between parser steps. The Perl grammar's external scanner looped forever on another window; no in-process timeout reaches inside a scanner. So the pipeline verifies in a worker process it can kill (`Verifier`), and the detector's parse check stays opt-in.
  - Training is resumable: `seed` drives the trainer's per-epoch shuffle, and a `checkpoint:` file holds policy, optimizer state and `RLCD::Checkpoint`. `resume` refuses a file whose labels, featurizer, hidden size or seed differ, instead of silently mixing runs.
- **Bundled model.**
  - `scripts/model.cr` is the only producer of `models/`. Never edit `models/languages.rlcd` or `models/REPORT.md` by hand; change the manifest, `sources.yml` or the pipeline and rebuild.
  - Labels must be verifiable: every sample is parsed with its own grammar and kept only within `Collector::MAX_ERROR`. Real files are labelled by extension; an extension two grammars claim (`h`) labels nothing.
  - Splits are by group (corpus case, example file, source repository), never by window, so the test set never shares a file or repository with training.
  - The gate (`Evaluation::GATE`) applies to the model alone, which is what `Detector.default` users get: ECE < 3%, family accuracy ≥ 80% on 6–15-line and ≥ 90% on 16+-line snippets. Shorter snippets are too ambiguous to gate on (1–2 lines reached ~51% across 52 languages). A failed build writes only `build/REPORT.md`.
  - The manifest was halved from 52 to 26 grammars (the common ones plus Crystal). With 52 the linear model reached 86% family accuracy on 6+ lines; dropped grammars include Julia and Perl, whose grammars misbehaved, and tsx/objc, the largest confusion sources.
  - The shipped model is I8 without optimizer state; `build/languages.full.rlcd` keeps the full model for resuming. Only weights ship, never corpus text.
  - Memory. A build once exhausted a 15 GB laptop (uncapped collection, calibration and test sets) and froze it. Keep every stage bounded:
    - `build` re-executes itself under `systemd-run --user --scope -p MemoryMax=<--memory>M -p MemorySwapMax=0`, so running out of memory kills the build cleanly. `--no-scope` exists for machines without systemd; do not make it the default.
    - Collection keeps at most `(cap + CAL_CAP + TEST_CAP) × 2` candidates per language (reservoir sampling) and deduplicates by hash, so its memory does not grow with the corpus.
    - Training holds dense features (`dim` × 8 bytes per training and calibration sample). `build` estimates that before training and aborts above `MEMORY_SHARE` of `--memory`; the defaults (dim 4096, cap 1000, ~50 languages) need about 2 GB.
    - Evaluation runs at most `TEST_CAP` samples per language.
  - Restarts are cheap. `build/samples.jsonl` is reused while its stamp (manifest, sources.yml, `Collector::SETTINGS`, budget, seed) matches. `build/checkpoint.rlcd` is saved after every epoch and resumed while `checkpoint.rlcd.stamp` (sample stamp, `Split::SETTINGS`, dim, lr, cap, seed) matches and the checkpoint is not past `--epochs`; otherwise it is deleted. Raising `--epochs` continues the same run; lowering it starts over. (30 epochs overfit: 72.6% → 71.3% accuracy, temperature 1.9 → 3.1, against 15.)
- **Man pages.**
  - `man/` is generated by the maintainer's `docv` tool (`~/.local/bin/docv`, not a shard dependency). `docv gen-cr`, run anywhere in the shard, reads `README.md` and the doc comments (through `crystal docs --format json`). It writes `man/man7/treesitter.7cr` and one `man/man3/<Type>.3cr` per documented type.
  - Never edit a page by hand. Change the doc comments or `README.md`, then rerun `docv gen-cr`.
  - `gen-cr` rewrites only pages whose content changed, so unchanged pages keep their date. It deletes generated pages whose type is gone or became `:nodoc:`. It touches only files that carry its `Generated by docv gen-cr` comment.
  - The pages are committed, so users read them from the checkout (`man -l lib/treesitter/man/...`, `MANPATH`, or `docv`); nothing installs them.

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
  - Public declarations that are internal get `# :nodoc:` alone, so `crystal docs` and the man pages leave them out. These are `LibTreeSitter`, `Predicate` and `Query#predicates`, the C interop (`to_unsafe`, `to_lib`, `Point.of`, `Region.of`, the `Node`/`Tree` pointer constructors), `finalize`, `QueryError.new` and `Fixture::SOURCES`.
  - Private and `:nodoc:` code gets a plain comment only where the reason is not obvious from the code. Use comments sparingly: no section banners, no commented-out code, no change notes.
- Keep the user-facing API ergonomic.
- Prevent shotgun surgery: one concept, one place.
- Match the surrounding style: aligned assignments, explicit return types, `@[AlwaysInline]` on hot accessors.
- Do not add functionality nobody asked for.
- Deliver complete files: no stubs, no placeholders.
- Do not change `version` in `shard.yml`.
- Keep `README.md` and `AGENTS.md` in sync with the code, and regenerate `man/` in the same commit as the doc comment or README change.
- Write everything in English.
