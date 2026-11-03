# src/tree_sitter/detector.cr

module TreeSitter
  # Guesses the language of source text that has no file name, such as a snippet. A calibrated `RLCD::Model` trained
  # on code samples ranks the languages. Then the grammars of the most probable ones parse the text, and candidates
  # whose parse has errors lose probability to those that parse cleanly. Labels are grammar names for
  # `Language.find`. A detector reuses one `Parser`, so it is not safe to share between threads.
  class Detector
    # Bytes of error that each node inserted by the parser (`Node#missing?`) counts for.
    MISSING_BYTES = 1

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
    # How many of the most probable languages get the parse check.
    property checked : Int32
    # How strongly parse errors count: a checked candidate's probability is multiplied by `exp(-penalty * error_ratio)`
    # before the checked candidates share their probability again.
    property penalty : Float64
    # The probability `Detection#language` needs by default.
    property threshold : Float64

    @grammars = {} of String => Language?
    @parser : Parser?

    # A detector over *model*, whose labels are grammar names.
    def initialize(@model : RLCD::Model, @checked : Int32 = 3, @penalty : Float64 = 1.0, @threshold : Float64 = 0.5)
    end

    # Trains a detector on *samples*: grammar name → code snippets, for at least two languages with a snippet each.
    # Snippets hash into *dim* code features with *seed*. A linear head (or a *hidden* layer) learns with the log score
    # for *epochs* at rate *lr*. A temperature fitted on the *validation* share of each language's snippets
    # calibrates it. The model keeps the optimizer state, so training can resume.
    def self.train(samples : Hash(String, Array(String)), *, dim : Int32 = 4096, seed : UInt64 = 42_u64,
                   hidden : Int32 = 0, epochs : Int32 = 60, lr : Float64 = 0.01, validation : Float64 = 0.15,
                   rng : Random = Random.new) : Detector
      raise ArgumentError.new("need samples for at least two languages, got #{samples.size}") if samples.size < 2
      if empty = samples.find { |_, texts| texts.empty? }
        raise ArgumentError.new("no samples for #{empty[0]}")
      end
      raise ArgumentError.new("validation must be in 0.0...1.0, got #{validation}") unless 0.0 <= validation < 1.0

      featurizer = RLCD::Featurizer.new(dim: dim, seed: seed, code: true)
      training   = [] of RLCD::Example
      held_out   = [] of RLCD::Example
      samples.each_with_index do |(_, texts), label|
        examples = texts.map { |text| RLCD::Example.new(featurizer.features(text, "", ""), label) }.shuffle!(rng)
        held     = (examples.size * validation).to_i
        held_out.concat(examples[0, held])
        training.concat(examples[held..])
      end

      policy  = RLCD::Policy.new(input_dim: dim, hidden_dim: hidden, option_count: samples.size, rng: rng)
      trainer = RLCD::Trainer.new(policy: policy, lr: lr, scoring: RLCD::ScoringRule::LogScore, rng: rng)
      trainer.train(training, epochs)
      temperature = held_out.empty? ? 1.0 : RLCD.fit_temperature(held_out.map { |example| policy.forward(example.features).logits }, held_out.map(&.label))
      new(RLCD::Model.new(featurizer, policy, samples.keys, temperature, trainer.optimizer))
    end

    # Loads a detector saved with `save`, JSON or binary (detected from the content); raises `RLCD::FormatError` for a
    # malformed file.
    def self.load(path : String) : Detector
      new(RLCD::Model.load(path))
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
    # well their grammars parse it. Their share of the total stays the same. Languages without a loadable grammar
    # are not reweighted.
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
      root = parser.parse(text).root
      return 0.0 unless root.has_error?
      {error_bytes(root) / {text.bytesize, 1}.max, 1.0}.min
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

    private def error_bytes(node : Node) : Int32
      return node.end_byte - node.start_byte if node.error?
      return MISSING_BYTES if node.missing?
      return 0 unless node.has_error?
      (0...node.child_count).sum { |index| node.child(index).try { |child| error_bytes(child) } || 0 }
    end
  end
end
