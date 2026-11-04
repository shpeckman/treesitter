# scripts/model.cr
#
# Builds the bundled detector model (`models/languages.rlcd`, `TreeSitter::Detector.default`) from the grammars in
# `scripts/languages.yml` and the real-code repositories in `scripts/sources.yml`:
#
#   crystal build --threads 2 --release -o build/model scripts/model.cr
#   build/model discover [--repos N]   # search GitHub, write scripts/sources.yml
#   build/model fetch                  # sparse checkouts into build/
#   build/model build [--dim N] [--epochs N] [--lr F] [--cap N] [--seed N] [--memory MB] [--no-scope]
#   build/model verify                 # worker: verifies JSON-line requests on stdin (started by build)
#
# `build` re-executes itself in a systemd user scope with MemoryMax=--memory and no swap, so running out of memory
# kills the build, not the machine. It reuses build/samples.jsonl while the inputs are unchanged, resumes training
# from build/checkpoint.rlcd, evaluates the quantized model and writes build/REPORT.md. Only when the gate in
# `scripts/model/evaluation.cr` passes does it replace `models/languages.rlcd` and `models/REPORT.md`; otherwise it
# exits with status 1.

require "option_parser"
require "../src/detect"
require "./model/cache"
require "./model/collect"
require "./model/evaluation"
require "./model/fetch"
require "./model/manifest"
require "./model/sources"
require "./model/split"
require "./model/verify"

module ModelBuild
  ROOT         = File.expand_path("..", __DIR__)
  MANIFEST     = File.join(ROOT, "scripts", "languages.yml")
  SOURCES      = File.join(ROOT, "scripts", "sources.yml")
  BUILD        = File.join(ROOT, "build")
  REPOS        = File.join(BUILD, "repos")
  CODE         = File.join(BUILD, "sources")
  SAMPLES      = File.join(BUILD, "samples.jsonl")
  CHECKPOINT   = File.join(BUILD, "checkpoint.rlcd")
  MODELS       = File.join(ROOT, "models")
  PRECISION    = RLCD::Precision::I8
  SCOPE_ENV    = "MODEL_BUILD_SCOPE"
  MEMORY_SHARE = 0.6

  # The settings of one build.
  record Options, dim : Int32, epochs : Int32, lr : Float64, cap : Int32, seed : UInt64, memory : Int32

  def self.fetch(grammars : Array(Grammar), sources : Array(Source)) : Array(String)
    Fetch.grammars(grammars, REPOS) + Fetch.sources(sources, Extensions.new(grammars), CODE)
  end

  # Runs this program again inside a systemd user scope limited to *memory* MB without swap, unless already inside.
  def self.scope(memory : Int32, arguments : Array(String)) : Nil
    return if ENV[SCOPE_ENV]?
    runner = Process.find_executable("systemd-run") || abort("systemd-run not found: rerun with --no-scope to build without a memory limit")
    ENV[SCOPE_ENV] = memory.to_s
    Process.exec(runner, ["--user", "--scope", "--quiet", "-p", "MemoryMax=#{memory}M", "-p", "MemorySwapMax=0",
                          Process.executable_path || abort("cannot locate this executable")] + arguments)
  end

  def self.build(options : Options) : Bool
    grammars   = Manifest.load(MANIFEST)
    sources    = Sources.load(SOURCES)
    extensions = Extensions.new(grammars)
    unfetched  = fetch(grammars, sources)
    budget     = (options.cap + Split::CAL_CAP + Split::TEST_CAP) * 2
    stamp      = Cache.stamp(File.read(MANIFEST), File.exists?(SOURCES) ? File.read(SOURCES) : "", Collector::SETTINGS, budget, options.seed)

    samples, tallies, collection = collect(grammars, sources, extensions, budget, stamp, options.seed)
    sets = Split.run(samples, options.cap, Random.new(options.seed))
    held = sets.train.sum(&.[1].size) + sets.calibration.sum(&.[1].size)
    need = held.to_i64 * options.dim * 8
    STDERR.puts "training on #{sets.train.sum(&.[1].size)} samples, #{sets.train.size} languages; features need #{need // 1_048_576} MB"
    limit = (options.memory.to_i64 * 1_048_576 * MEMORY_SHARE).to_i64
    abort("features need #{need // 1_048_576} MB, over #{(MEMORY_SHARE * 100).to_i}% of the #{options.memory} MB limit: lower --cap or --dim, or raise --memory") if need > limit

    resumable = Cache.stamp(stamp, Split::SETTINGS, options.dim, options.lr, options.cap, options.seed)
    marker    = "#{CHECKPOINT}.stamp"
    past = File.exists?(CHECKPOINT) && (RLCD::Model.load(CHECKPOINT).checkpoint.try(&.epoch) || 0) > options.epochs
    unless !past && File.exists?(marker) && File.read(marker) == resumable
      File.delete?(CHECKPOINT)
      File.write(marker, resumable)
    end
    started = Time.instant
    trained = TreeSitter::Detector.train(sets.train, dim: options.dim, epochs: options.epochs, lr: options.lr, seed: options.seed,
      calibration: sets.calibration, checkpoint: CHECKPOINT, rng: Random.new(options.seed))
    duration = Time.instant - started
    trained.save(File.join(BUILD, "languages.full.rlcd"))

    model = trained.model
    io    = IO::Memory.new
    RLCD::Model.new(model.featurizer, model.policy, model.labels, model.temperature).to_io(io, IO::ByteFormat::LittleEndian, PRECISION)
    shipped  = io.to_slice
    detector = TreeSitter::Detector.new(RLCD::Model.from_io(IO::Memory.new(shipped, writable: false)))

    families = grammars.to_h { |grammar| {grammar.name, grammar.family} }
    results  = Evaluation.run(detector, sets.test, families)
    failures = Evaluation.gate(results)
    settings = {
      "Languages"     => sets.train.size.to_s,
      "Collection"    => "#{collection}, at most #{budget} candidates per language",
      "Training"      => "#{sets.train.sum(&.[1].size)} samples (at most #{options.cap} per language, #{Split::GROUP_CAP} per group), #{options.epochs} epochs, lr #{options.lr}",
      "Featurizer"    => "code, dim #{options.dim}, seed #{options.seed}",
      "Head"          => "linear, log score",
      "Temperature"   => model.temperature.round(4).to_s,
      "Model"         => "#{PRECISION}, weights only, #{shipped.size} bytes",
      "Memory"        => "features #{need // 1_048_576} MB, scope limit #{ENV[SCOPE_ENV]? ? "#{options.memory} MB" : "none (--no-scope)"}",
      "Training time" => "#{duration.total_seconds.round(1)} s",
      "Evaluation"    => "model only (the default; the parse check is opt-in and runs grammar code on the text, so the build does not run it in-process)",
      "Verification"  => "worker process, parse budget #{Verifier::PARSE_TIMEOUT.total_milliseconds.to_i} ms, deadline #{Verifier::DEADLINE.total_seconds.to_i} s per candidate",
    }
    report = Evaluation.report(grammars, tallies, sources, unfetched, extensions.shared, sets, results, failures, settings)
    File.write(File.join(BUILD, "REPORT.md"), report)
    STDERR.puts failures.empty? ? "gate passed" : "gate failed:\n  #{failures.join("\n  ")}"
    return false unless failures.empty?

    Dir.mkdir_p(MODELS)
    File.write(File.join(MODELS, "languages.rlcd"), shipped)
    File.write(File.join(MODELS, "REPORT.md"), report)
    true
  end

  private def self.collect(grammars : Array(Grammar), sources : Array(Source), extensions : Extensions, budget : Int32,
                           stamp : String, seed : UInt64) : {Array(Sample), Hash(String, Tally), String}
    if cached = Cache.load(SAMPLES, stamp)
      STDERR.puts "reusing #{cached[0].size} samples from #{SAMPLES}"
      return {cached[0], cached[1], "cached"}
    end
    collector = Collector.new(grammars, budget, Random.new(seed))
    collector.grammars(REPOS)
    collector.sources(sources, extensions, CODE)
    verifier = Verifier.new(Process.executable_path || abort("cannot locate this executable"))
    samples  = collector.samples(verifier)
    verifier.close
    STDERR.puts "collected #{samples.size} verified samples"
    Cache.write(SAMPLES, stamp, samples, collector.tallies)
    {samples, collector.tallies, "collected"}
  end
end

arguments = ARGV.dup
command   = ARGV.first?.try(&.starts_with?('-')) == false ? ARGV.shift : "build"
dim       = 4096
epochs    = 15
lr        = 0.01
cap       = 1000
seed      = 42_u64
repos     = 12
memory    = 4096
scoped    = true
OptionParser.parse do |parser|
  parser.banner = "Usage: build/model [discover|fetch|build] [options]"
  parser.on("--repos N", "discover: repositories per GitHub language (default #{repos})") { |value| repos = value.to_i }
  parser.on("--dim N", "Featurizer dimension (default #{dim})") { |value| dim = value.to_i }
  parser.on("--epochs N", "Training epochs (default #{epochs})") { |value| epochs = value.to_i }
  parser.on("--lr F", "Learning rate (default #{lr})") { |value| lr = value.to_f }
  parser.on("--cap N", "Training samples per language at most (default #{cap})") { |value| cap = value.to_i }
  parser.on("--seed N", "Random seed (default #{seed})") { |value| seed = value.to_u64 }
  parser.on("--memory MB", "Memory limit of the build scope (default #{memory})") { |value| memory = value.to_i }
  parser.on("--no-scope", "Build without the systemd memory scope") { scoped = false }
  parser.on("-h", "--help", "Show this help") { puts parser; exit }
end

case command
when "discover"
  ModelBuild::Sources.write(ModelBuild::SOURCES, ModelBuild::Sources.discover(ModelBuild::Manifest.load(ModelBuild::MANIFEST), repos))
when "fetch"
  failures = ModelBuild.fetch(ModelBuild::Manifest.load(ModelBuild::MANIFEST), ModelBuild::Sources.load(ModelBuild::SOURCES))
  exit(failures.empty? ? 0 : 1)
when "verify"
  ModelBuild::Verifier.serve(STDIN, STDOUT)
when "build"
  ModelBuild.scope(memory, arguments) if scoped
  exit(ModelBuild.build(ModelBuild::Options.new(dim, epochs, lr, cap, seed, memory)) ? 0 : 1)
else
  STDERR.puts "unknown command #{command}; use discover, fetch, build or verify"
  exit 2
end
