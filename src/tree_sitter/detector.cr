# src/tree_sitter/detector.cr

module TreeSitter
  # Guesses the language of source text that has no file name, such as a snippet. A calibrated `RLCD::Model` trained
  # on code samples ranks the languages; labels are grammar names for `Language.find`. Optionally (`checked` > 0) the
  # grammars of the most probable ones parse the text, and candidates whose parse has errors lose probability to
  # those that parse cleanly. A detector reuses one `Parser`, so it is not safe to share between threads.
  class Detector
    # A language `Detector#detect` considered: its `probability` after the parse check, and `error_ratio`, the share
    # of the text (0.0 to 1.0) its grammar could not parse, `nil` when the grammar was not checked.
    record Candidate, language : String, probability : Float64, error_ratio : Float64?

    # The result of `Detector#detect`: one `Candidate` per label, most probable first.
    record Detection, candidates : Array(Candidate), threshold : Float64 do
      # The most probable candidate.
      def best : Candidate
        candidates.first
      end

      # The most probable language, or `nil` when its probability is below `threshold`.
      def language : String?
        best.language if best.probability >= threshold
      end

      # The probability of the most probable language.
      def probability : Float64
        best.probability
      end
    end

    # The classifier: code featurizer, policy, labels and temperature.
    getter model : RLCD::Model
    # How many of the most probable languages get the parse check; 0 (the default) keeps the model's probabilities.
    # The check runs the installed grammars' C code on the text, and some grammars' external scanners can loop
    # forever on unexpected input, which `timeout` cannot interrupt; enable it only for grammars you trust.
    property checked : Int32
    # How strongly parse errors count: a checked candidate's probability is multiplied by `exp(-penalty * error_ratio)`
    # before the checked candidates share their probability again.
    property penalty : Float64
    # The probability `Detection#language` needs by default.
    property threshold : Float64
    # How long one candidate's parse check may take; a candidate whose parse runs out of time is not reweighted.
    property timeout : Time::Span

    @grammars = {} of String => Language?
    @parser : Parser?

    # A detector over *model*, whose labels are grammar names.
    def initialize(@model : RLCD::Model, @checked : Int32 = 0, @penalty : Float64 = 1.0, @threshold : Float64 = 0.5,
                   @timeout : Time::Span = 50.milliseconds)
    end

    # The bundled detector, built by `scripts/model.cr` from the test corpora and examples of the Tier 1 grammars;
    # `models/REPORT.md` lists its languages and measured accuracy. Each call returns a new detector, so each fiber
    # can hold its own.
    def self.default : Detector
      new(RLCD::Model.from_io(IO::Memory.new({{ read_file("#{__DIR__}/../../models/languages.rlcd") }}.to_slice, writable: false)))
    end

    # Trains a detector on *samples*: grammar name → code snippets, for at least two languages with a snippet each.
    # Snippets hash into *dim* code features with *seed*, which also fixes each epoch's shuffle order. A linear head
    # (or a *hidden* layer) learns with the log score for *epochs* at rate *lr*. A temperature calibrates it, fitted on
    # *calibration* (grammar name → snippets kept apart from *samples*) when given, otherwise on the *validation* share
    # of each language's snippets. The model keeps the optimizer state, so training can resume.
    #
    # With *checkpoint*, a path, the run saves its state there after every epoch (atomically), and a run that finds
    # the file continues after its last completed epoch, reaching the weights of an uninterrupted run. Raises
    # `ArgumentError` when the file belongs to another run (labels, featurizer, *hidden* or *seed* differ) or is already
    # past *epochs*.
    def self.train(samples : Hash(String, Array(String)), *, dim : Int32 = 4096, seed : UInt64 = 42_u64,
                   hidden : Int32 = 0, epochs : Int32 = 60, lr : Float64 = 0.01, validation : Float64 = 0.15,
                   calibration : Hash(String, Array(String))? = nil, checkpoint : String? = nil,
                   rng : Random = Random.new) : Detector
      raise ArgumentError.new("need samples for at least two languages, got #{samples.size}") if samples.size < 2
      if empty = samples.find { |_, texts| texts.empty? }
        raise ArgumentError.new("no samples for #{empty[0]}")
      end
      raise ArgumentError.new("validation must be in 0.0...1.0, got #{validation}") unless 0.0 <= validation < 1.0

      featurizer = RLCD::Featurizer.new(dim: dim, seed: seed, code: true)
      labels     = samples.keys
      share      = calibration ? 0.0 : validation
      training   = [] of RLCD::Example
      held_out   = [] of RLCD::Example
      samples.each_with_index do |(_, texts), label|
        examples = texts.map { |text| RLCD::Example.new(featurizer.features(text, "", ""), label) }.shuffle!(rng)
        held     = (examples.size * share).to_i
        held_out.concat(examples[0, held])
        training.concat(examples[held..])
      end
      calibration.try &.each do |language, texts|
        label = labels.index(language) || raise ArgumentError.new("calibration language #{language} has no samples")
        texts.each { |text| held_out << RLCD::Example.new(featurizer.features(text, "", ""), label) }
      end

      saved   = checkpoint.try { |path| resume(path, featurizer, labels, hidden, seed) }
      policy  = saved.try(&.policy) || RLCD::Policy.new(input_dim: dim, hidden_dim: hidden, option_count: labels.size, rng: rng)
      trainer = RLCD::Trainer.new(policy: policy, lr: lr, scoring: RLCD::ScoringRule::LogScore, rng: rng,
                                  optimizer: saved.try(&.optimizer), seed: seed)
      start = saved.try(&.checkpoint.try(&.epoch)) || 0
      raise ArgumentError.new("checkpoint #{checkpoint} is at epoch #{start}, past the requested #{epochs}") if start > epochs
      trainer.train(training, epochs, start) do
        next unless path = checkpoint
        RLCD::Model.new(featurizer, policy, labels, optimizer: trainer.optimizer, checkpoint: trainer.checkpoint).save(path)
      end
      temperature = held_out.empty? ? 1.0 : RLCD.fit_temperature(held_out.map { |example| policy.forward(example.features).logits }, held_out.map(&.label))
      new(RLCD::Model.new(featurizer, policy, labels, temperature, trainer.optimizer))
    end

    private def self.resume(path : String, featurizer : RLCD::Featurizer, labels : Array(String), hidden : Int32, seed : UInt64) : RLCD::Model?
      return nil unless File.exists?(path)
      saved  = RLCD::Model.load(path)
      found  = saved.featurizer
      reason = if saved.labels != labels
                 "labels differ"
               elsif {found.dim, found.seed, found.code?} != {featurizer.dim, featurizer.seed, featurizer.code?}
                 "featurizer differs"
               elsif saved.policy.hidden_dim != hidden
                 "hidden layer differs"
               elsif saved.optimizer.nil? || saved.checkpoint.try(&.seed) != seed
                 "no optimizer state or another seed"
               end
      raise ArgumentError.new("checkpoint #{path} belongs to another run: #{reason}") if reason
      saved
    end

    # Loads a detector saved with `save`, JSON or binary (detected from the content); raises `RLCD::FormatError` for a
    # malformed file.
    def self.load(path : String) : Detector
      new(RLCD::Model.load(path))
    end

    # The share of *text* (0.0 to 1.0) that the parse under *root* could not fit: `Node#error_bytes` over the text's
    # size.
    def self.error_ratio(root : Node, text : String) : Float64
      return 0.0 unless root.has_error?
      {root.error_bytes / {text.bytesize, 1}.max, 1.0}.min
    end

    # Saves the model to *path*: JSON for a `.json` extension, binary otherwise, with weights stored at *precision*
    # (binary only).
    def save(path : String, format : RLCD::Format = RLCD::Format.from_path(path), precision : RLCD::Precision = RLCD::Precision::F64) : Nil
      @model.save(path, format, precision)
    end

    # The languages the detector knows, as grammar names.
    def labels : Array(String)
      @model.labels
    end

    # Ranks the languages for *text*: the model's probabilities, with the `checked` most probable reweighted by how
    # well their grammars parse it. Their share of the total stays the same. Languages without a loadable grammar,
    # and those whose parse runs past `timeout`, are not reweighted.
    def detect(text : String, threshold : Float64 = @threshold) : Detection
      ranked  = @model.predict(text)
      checked = ranked.first(@checked.clamp(0, ranked.size))
      errors  = checked.map { |(language, _)| error_ratio(language, text) }
      weights = checked.map_with_index { |(_, probability), i| probability * (errors[i].try { |ratio| Math.exp(-@penalty * ratio) } || 1.0) }
      mass    = checked.sum(0.0, &.[1])
      total   = weights.sum(0.0)

      candidates = ranked.map_with_index do |(language, probability), i|
        if i < checked.size
          Candidate.new(language, total > 0.0 ? weights[i] / total * mass : probability, errors[i])
        else
          Candidate.new(language, probability, nil)
        end
      end
      Detection.new(candidates.sort_by! { |candidate| -candidate.probability }, threshold)
    end

    private def error_ratio(language : String, text : String) : Float64?
      grammar = grammar(language) || return nil
      parser  = @parser ||= Parser.new(grammar)
      parser.language = grammar
      tree = parser.parse(text, timeout: @timeout) || return nil
      Detector.error_ratio(tree.root, text)
    end

    private def grammar(language : String) : Language?
      @grammars.fetch(language) do
        @grammars[language] = begin
          Language.find(language).try { |path| Language.load(path, language) }
        rescue Error
          nil
        end
      end
    end
  end
end
