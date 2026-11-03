# spec/detector_spec.cr

require "./spec_helper"
require "../src/detect"

private SAMPLES = {
  "json"   => Array.new(40) { |i| %({"key_#{i}": [#{i}, true, null], "name": "item #{i}", "nested": {"v": #{i * 2}}}) },
  "ruby"   => Array.new(40) { |i| "def method_#{i}(value)\n  value.each { |x| puts x + #{i} }\nend\n" },
  "python" => Array.new(40) { |i| "def func_#{i}(value):\n    for x in value:\n        print(x * #{i})\n    return None\n" },
}

private def with_fixture_grammars(&)
  previous = TreeSitter::Language.directories
  TreeSitter::Fixture.library("json")
  TreeSitter::Language.directories = [TreeSitter::Fixture::DIRECTORY]
  yield
ensure
  TreeSitter::Language.directories = previous.not_nil!
end

private MODEL = TreeSitter::Detector.train(SAMPLES, dim: 1024, epochs: 40, rng: Random.new(7)).model

private def trained : TreeSitter::Detector
  TreeSitter::Detector.new(MODEL)
end

describe TreeSitter::Detector do
  it "detects the language of unseen snippets" do
    with_fixture_grammars do
      detector = trained
      detector.labels.should eq(["json", "ruby", "python"])
      detector.detect(%({"other": [false, 3.5], "list": []})).language.should eq("json")
      detector.detect("def greet(name)\n  name.each { |n| puts n }\nend\n").language.should eq("ruby")
      detector.detect("def greet(name):\n    for n in name:\n        print(n)\n").language.should eq("python")
    end
  end

  it "ranks every label, most probable first, with probabilities summing to one" do
    with_fixture_grammars do
      detection     = trained.detect("def x(v)\n  v\nend\n")
      probabilities = detection.candidates.map(&.probability)
      detection.candidates.map(&.language).sort.should eq(["json", "python", "ruby"])
      probabilities.should eq(probabilities.sort.reverse)
      probabilities.sum.should be_close(1.0, 1e-9)
      detection.probability.should eq(detection.best.probability)
    end
  end

  it "checks candidates with their grammars and lowers those that do not parse" do
    with_fixture_grammars do
      detector = trained
      clean    = detector.detect(%({"a": [1, 2]}))
      clean.candidates.find! { |candidate| candidate.language == "json" }.error_ratio.should eq(0.0)
      clean.candidates.find! { |candidate| candidate.language == "ruby" }.error_ratio.should be_nil

      broken = %({"a": [1, 2 ;; puts x)
      raw    = detector.model.predict(broken).to_h["json"]
      json   = detector.detect(broken).candidates.find! { |candidate| candidate.language == "json" }
      json.error_ratio.not_nil!.should be > 0.0
      json.probability.should be < raw
    end
  end

  it "keeps the model's probabilities when nothing is checked" do
    with_fixture_grammars do
      detector = trained
      detector.checked = 0
      text = %({"a": [1, 2 ;; puts x)
      detector.detect(text).candidates.map { |candidate| {candidate.language, candidate.probability} }.should eq(detector.model.predict(text))
      detector.detect(text).candidates.all?(&.error_ratio.nil?).should be_true
    end
  end

  it "reports no language below the threshold" do
    with_fixture_grammars do
      detection = trained.detect(%({"a": 1}), threshold: 1.1)
      detection.language.should be_nil
      detection.best.language.should eq("json")
    end
  end

  it "saves and loads, JSON and binary" do
    with_fixture_grammars do
      detector = trained
      text     = "def f(v):\n    return v\n"
      {".json" => RLCD::Precision::F64, ".rlcd" => RLCD::Precision::I8}.each do |extension, precision|
        path = File.tempname("treesitter-detector", extension)
        detector.save(path, precision: precision)
        loaded = TreeSitter::Detector.load(path)
        File.delete(path)
        loaded.labels.should eq(detector.labels)
        loaded.detect(text).language.should eq(detector.detect(text).language)
        loaded.detect(text).probability.should be_close(detector.detect(text).probability, 0.02)
        loaded.model.optimizer.should_not be_nil
      end
    end
  end

  it "rejects unusable training samples" do
    expect_raises(ArgumentError, /at least two languages/) { TreeSitter::Detector.train({"json" => ["{}"]}) }
    expect_raises(ArgumentError, /no samples for ruby/) { TreeSitter::Detector.train({"json" => ["{}"], "ruby" => [] of String}) }
    expect_raises(ArgumentError, /validation/) { TreeSitter::Detector.train(SAMPLES, validation: 1.0) }
  end
end
