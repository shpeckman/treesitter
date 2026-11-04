# scripts/model/evaluation.cr

require "./manifest"
require "./split"

module ModelBuild
  # One test sample's result under one detector setting.
  record Outcome, language : String, predicted : String, top3 : Bool, family : Bool, lines : Int32,
    probabilities : Array(Float64), truth : Int32

  record Metrics, count : Int32, accuracy : Float64, top3 : Float64, family : Float64, ece : Float64

  # Scores the detector on the test set, per setting, length and language, and checks the ship gate.
  module Evaluation
    SETTINGS = {"model only" => 0}
    BUCKETS  = [{"1–2 lines", 1..2}, {"3–5 lines", 3..5}, {"6–15 lines", 6..15}, {"16+ lines", 16..Int32::MAX}]
    GATE     = {ece: 0.03, family: [{"6–15 lines", 6..15, 0.80}, {"16+ lines", 16..Int32::MAX, 0.90}]}

    def self.run(detector : TreeSitter::Detector, test : Array(Sample), families : Hash(String, String)) : Hash(String, Array(Outcome))
      labels = detector.labels
      SETTINGS.to_h do |name, checked|
        detector.checked = checked
        outcomes = test.map do |sample|
          candidates = detector.detect(sample.text).candidates
          predicted  = candidates.first.language
          Outcome.new(
            sample.language,
            predicted,
            candidates.first(3).any? { |candidate| candidate.language == sample.language },
            families[predicted] == families[sample.language],
            sample.text.lines.size,
            labels.map { |label| candidates.find!(&.language.==(label)).probability },
            labels.index!(sample.language),
          )
        end
        {name, outcomes}
      end
    end

    def self.metrics(outcomes : Array(Outcome)) : Metrics
      return Metrics.new(0, 0.0, 0.0, 0.0, 0.0) if outcomes.empty?
      size = outcomes.size.to_f
      ece, _ = RLCD.ece(outcomes.map { |outcome| {outcome.probabilities, outcome.truth} })
      Metrics.new(
        outcomes.size,
        outcomes.count { |outcome| outcome.predicted == outcome.language } / size,
        outcomes.count(&.top3) / size,
        outcomes.count(&.family) / size,
        ece,
      )
    end

    def self.gate(results : Hash(String, Array(Outcome))) : Array(String)
      results.flat_map do |name, outcomes|
        overall  = metrics(outcomes)
        failures = [] of String
        failures << "#{name}: ECE #{percent(overall.ece, 2)} ≥ #{percent(GATE[:ece], 0)}" unless overall.ece < GATE[:ece]
        GATE[:family].each do |(label, range, minimum)|
          family = metrics(outcomes.select { |outcome| range.includes?(outcome.lines) }).family
          failures << "#{name}: family accuracy on #{label} #{percent(family)} < #{percent(minimum, 0)}" unless family >= minimum
        end
        failures
      end
    end

    def self.report(grammars : Array(Grammar), tallies : Hash(String, Tally), sources : Array(Source), unfetched : Array(String),
                    shared : Array(String), sets : Sets, results : Hash(String, Array(Outcome)),
                    failures : Array(String), settings : Hash(String, String)) : String
      String.build do |io|
        io << "# Detector model report\n\n"
        io << "Built by `scripts/model.cr` from the test corpora and examples of the grammars in `scripts/languages.yml`.\n\n"
        io << "**Gate:** " << (failures.empty? ? "passed" : "failed") << " (ECE < #{percent(GATE[:ece], 0)}, family accuracy " << GATE[:family].map { |(label, _, minimum)| "≥ #{percent(minimum, 0)} on #{label}" }.join(" and ") << ")\n"
        failures.each { |failure| io << "- " << failure << '\n' }
        io << "\n## Settings\n\n| Setting | Value |\n|---|---|\n"
        settings.each { |key, value| io << "| " << key << " | " << value << " |\n" }

        io << "\n## Results\n\n| Setting | Samples | Accuracy | Top-3 | Family | ECE |\n|---|---|---|---|---|---|\n"
        results.each do |name, outcomes|
          row(io, name, metrics(outcomes))
        end

        io << "\n## By snippet length\n\n| Lines |"
        results.each_key { |name| io << ' ' << name << " accuracy | " << name << " family |" }
        io << "\n|---|" << "---|---|" * results.size << '\n'
        BUCKETS.each do |(label, range)|
          io << "| " << label << " (" << results.first_value.count { |outcome| range.includes?(outcome.lines) } << ") |"
          results.each_value do |outcomes|
            bucket = metrics(outcomes.select { |outcome| range.includes?(outcome.lines) })
            io << ' ' << percent(bucket.accuracy) << " | " << percent(bucket.family) << " |"
          end
          io << '\n'
        end

        io << "\n## Languages\n\n| Language | Family | Corpus cases | Files | Repos | Windows | Rejected | Timeouts | Duplicates | Train | Calibration | Test |"
        results.each_key { |name| io << ' ' << name << " |" }
        io << "\n|---|---|---|---|---|---|---|---|---|---|---|---|" << "---|" * results.size << '\n'
        grammars.each do |grammar|
          found = tallies[grammar.name]
          next if sets.excluded.has_key?(grammar.name) || found.note
          io << "| " << grammar.name << " | " << grammar.family << " | " << found.cases << " | " << found.files << " | "
          io << found.repos.size << " | " << found.windows << " | " << found.rejected << " | " << found.timeouts << " | " << found.duplicates << " | "
          io << sets.train[grammar.name].size << " | " << sets.calibration[grammar.name].size << " | "
          io << sets.test.count(&.language.==(grammar.name)) << " |"
          results.each_value do |outcomes|
            io << ' ' << percent(metrics(outcomes.select(&.language.==(grammar.name))).accuracy) << " |"
          end
          io << '\n'
        end

        io << "\n## Sources\n\n"
        io << "Grammar corpora and examples: " << grammars.map(&.license).tally.to_a.sort_by! { |(_, count)| -count }.map { |(license, count)| "#{license} (#{count})" }.join(", ") << ".\n\n"
        io << "Real code: " << sources.size << " repositories from `scripts/sources.yml`, licenses "
        io << sources.map(&.license).tally.to_a.sort_by! { |(_, count)| -count }.map { |(license, count)| "#{license} (#{count})" }.join(", ") << ".\n"
        io << "Extensions shared by several grammars, so not used as labels: " << shared.map { |entry| "`#{entry}`" }.join(", ") << ".\n" unless shared.empty?
        unfetched.each { |failure| io << "- not fetched: " << failure << '\n' }
        io << "\n| GitHub language | Repositories |\n|---|---|\n"
        sources.group_by(&.language).each { |language, found| io << "| " << language << " | " << found.size << " |\n" }

        skipped = tallies.compact_map { |language, found| found.note.try { |note| {language, note} } } + sets.excluded.to_a
        unless skipped.empty?
          io << "\n## Not in the model\n\n| Language | Reason |\n|---|---|\n"
          skipped.each { |(language, reason)| io << "| " << language << " | " << reason << " |\n" }
        end

        io << "\n## Most frequent confusions\n\n| Language | Detected as | Count |\n|---|---|---|\n"
        results.first_value.reject { |outcome| outcome.predicted == outcome.language }
          .map { |outcome| {outcome.language, outcome.predicted} }.tally.to_a.sort_by! { |(_, count)| -count }.first(15)
          .each { |((language, predicted), count)| io << "| " << language << " | " << predicted << " | " << count << " |\n" }
      end
    end

    private def self.row(io : IO, name : String, metrics : Metrics) : Nil
      io << "| " << name << " | " << metrics.count << " | " << percent(metrics.accuracy) << " | " << percent(metrics.top3)
      io << " | " << percent(metrics.family) << " | " << metrics.ece.round(4) << " |\n"
    end

    private def self.percent(value : Float64, digits : Int32 = 1) : String
      "#{(value * 100).round(digits)}%"
    end
  end
end
