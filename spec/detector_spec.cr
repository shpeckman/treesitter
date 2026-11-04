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
      detector.checked = 3
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

  it "does not reweight a candidate whose parse runs out of time" do
    with_fixture_grammars do
      detector = trained
      detector.checked = 3
      detector.timeout = 0.seconds
      long = "[" + (["1"] * 200_000).join(", ") + "]"
      detector.detect(long).candidates.find! { |candidate| candidate.language == "json" }.error_ratio.should be_nil
    end
  end

  it "keeps the model's probabilities by default, when nothing is checked" do
    with_fixture_grammars do
      detector = trained
      detector.checked.should eq(0)
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

  it "fits the temperature on a separate calibration set" do
    calibration = SAMPLES.transform_values(&.first(5))
    detector    = TreeSitter::Detector.train(SAMPLES.transform_values(&.[5..]), dim: 256, epochs: 5, calibration: calibration, rng: Random.new(3))
    detector.model.temperature.should be > 0.0
    detector.detect(%({"a": [1]})).language.should eq("json")
    expect_raises(ArgumentError, /calibration language lua/) do
      TreeSitter::Detector.train(SAMPLES, dim: 64, epochs: 1, calibration: {"lua" => ["x = 1"]})
    end
  end

  it "measures the share of the text a parse could not fit" do
    parser = TreeSitter::Parser.new(JSON_GRAMMAR)
    TreeSitter::Detector.error_ratio(parser.parse("[1]").root, "[1]").should eq(0.0)
    text = "[1, @@@@@@ 2]"
    TreeSitter::Detector.error_ratio(parser.parse(text).root, text).should be > 0.3
    TreeSitter::Detector.error_ratio(parser.parse("@@@@").root, "@@@@").should eq(1.0)
  end

  it "resumes from a checkpoint to the weights of an uninterrupted run" do
    path = File.tempname("treesitter-detector-checkpoint", ".rlcd")
    TreeSitter::Detector.train(SAMPLES, dim: 256, epochs: 3, checkpoint: path, rng: Random.new(1))
    RLCD::Model.load(path).checkpoint.should eq(RLCD::Checkpoint.new(3, 3, 42_u64))
    resumed  = TreeSitter::Detector.train(SAMPLES, dim: 256, epochs: 6, checkpoint: path, rng: Random.new(1))
    straight = TreeSitter::Detector.train(SAMPLES, dim: 256, epochs: 6, rng: Random.new(1))
    RLCD::Model.load(path).checkpoint.not_nil!.epoch.should eq(6)
    resumed.model.policy.param_slices.map(&.to_a).should eq(straight.model.policy.param_slices.map(&.to_a))
    resumed.model.temperature.should eq(straight.model.temperature)
    expect_raises(ArgumentError, /at epoch 6, past the requested 4/) do
      TreeSitter::Detector.train(SAMPLES, dim: 256, epochs: 4, checkpoint: path, rng: Random.new(1))
    end
    expect_raises(ArgumentError, /belongs to another run: labels differ/) do
      TreeSitter::Detector.train(SAMPLES.reject("python"), dim: 256, epochs: 6, checkpoint: path)
    end
    expect_raises(ArgumentError, /featurizer differs/) do
      TreeSitter::Detector.train(SAMPLES, dim: 256, epochs: 6, seed: 7_u64, checkpoint: path)
    end
    File.delete(path)
  end

  it "rejects unusable training samples" do
    expect_raises(ArgumentError, /at least two languages/) { TreeSitter::Detector.train({"json" => ["{}"]}) }
    expect_raises(ArgumentError, /no samples for ruby/) { TreeSitter::Detector.train({"json" => ["{}"], "ruby" => [] of String}) }
    expect_raises(ArgumentError, /validation/) { TreeSitter::Detector.train(SAMPLES, validation: 1.0) }
  end
end
