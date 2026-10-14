# spec/syntax_spec.cr
require "./spec_helper"

CRYSTAL = <<-CODE
  class Foo < Bar
    MAX = 1
    def go(x)
      return "é\#{x}" if x # 👍
    end
  end
  CODE

describe TreeSitter::Syntax do
  it "highlights a line with the capture names of the language's query" do
    subject = document(CRYSTAL)
    syntax  = TreeSitter::Syntax.new(subject, TreeSitter.language("crystal"))
    buffer  = subject.buffer
    kinds(syntax, buffer, 0).should eq([{"class", "keyword"}, {"Foo", "type"}])
    kinds(syntax, buffer, 1).should eq([{"MAX", "constant"}, {"=", "operator"}, {"1", "number"}])
    kinds(syntax, buffer, 2).should eq([{"def", "keyword"}, {"go", "function.method"}, {"(", "punctuation.bracket"},
                                        {"x", "variable.parameter"}, {")", "punctuation.bracket"}])
    kinds(syntax, buffer, 3).last.should eq({"# 👍", "comment"})
    syntax.tokens(buffer, 99).should be_empty
  end

  it "counts token columns in clusters, not bytes" do
    subject = document(%(["é👍", 1]))
    syntax  = TreeSitter::Syntax.new(subject, TreeSitter.language("json"))
    tokens  = syntax.tokens(subject.buffer, 0)
    tokens.map { |token| {token.start, token.count, token.kind} }.should eq([{1, 4, "string"}, {7, 1, "number"}])
  end

  it "lets later patterns win by default, and earlier ones for languages that say so" do
    python = document("def f(a):\n    return None")
    kinds(TreeSitter::Syntax.new(python, TreeSitter.language("python")), python.buffer, 0)
      .should eq([{"def", "keyword"}, {"f", "function"}, {"a", "variable"}])
    json = document(%({"k": "v"}))
    kinds(TreeSitter::Syntax.new(json, TreeSitter.language("json")), json.buffer, 0)
      .should eq([{"\"k\"", "string.special.key"}, {"\"v\"", "string"}])
  end

  it "rehighlights lines whose syntax changed further away than the edit" do
    subject = document("int a;\nint b;\nint c;")
    syntax  = TreeSitter::Syntax.new(subject, TreeSitter.language("c"))
    buffer  = subject.buffer
    kinds(syntax, buffer, 1).should eq([{"int", "type"}, {"b", "variable"}, {";", "delimiter"}])
    subject.select_range(0, 0)
    subject.insert("/* ")
    3.times { |line| syntax.tokens(buffer, line) }
    subject.select_range(subject.length - 7, subject.length - 7)
    subject.insert(" */")
    subject.value.should eq("/* int a;\nint b; */\nint c;")
    kinds(syntax, buffer, 0).should eq([{"/* int a;", "comment"}])
    kinds(syntax, buffer, 1).should eq([{"int b; */", "comment"}])
    kinds(syntax, buffer, 2).should eq([{"int", "type"}, {"c", "variable"}, {";", "delimiter"}])
    subject.undo
    kinds(syntax, buffer, 1).should eq(fresh_tokens(subject, TreeSitter.language("c"))[1].map { |token| {buffer.line(1).slice(token.start, token.stop), token.kind} })
  end

  it "matches a fresh parse after random edits, transactions and undo" do
    random  = Random.new(11)
    pieces  = ["", "x", "é", "👍", "\n", "# c\n", "\"", "def y\nend\n", "(", ")", "  ", "1"]
    subject = document(CRYSTAL)
    crystal = TreeSitter.language("crystal")
    syntax  = TreeSitter::Syntax.new(subject, crystal)
    120.times do |round|
      if round % 10 == 9
        subject.undo
      elsif round % 7 == 6
        subject.transaction do
          2.times do
            at = random.rand(0..subject.length)
            subject.replace_ranges([Scribe::Edit.new(at...at, pieces.sample(random))])
          end
        end
      else
        from = random.rand(0..subject.length)
        to   = random.rand(from..Math.min(from + 5, subject.length))
        subject.replace_ranges([Scribe::Edit.new(from...to, pieces.sample(random))])
      end
      if round % 6 == 0
        Array.new(subject.buffer.line_count) { |line| syntax.tokens(subject.buffer, line) }.should eq(fresh_tokens(subject, crystal))
        syntax.tree.to_s.should eq(crystal.parse(subject.value).to_s)
      end
    end
    Array.new(subject.buffer.line_count) { |line| syntax.tokens(subject.buffer, line) }.should eq(fresh_tokens(subject, crystal))
  end

  it "follows value= and stops listening when closed" do
    subject = document("[1]")
    syntax  = TreeSitter::Syntax.new(subject, TreeSitter.language("json"))
    subject.value = "true\n"
    kinds(syntax, subject.buffer, 0).should eq([{"true", "constant.builtin"}])
    syntax.close
    subject.value = "[2]"
    syntax.tree.to_s.should eq("(document (true))")
  end

  it "picks a language from a path and finds the node at an offset" do
    subject = document("a = [1, 2]")
    TreeSitter::Syntax.for(subject, "notes.txt").should be_nil
    syntax = TreeSitter::Syntax.for(subject, "x.py").not_nil!
    syntax.language.name.should eq("python")
    syntax.node_at(8).try(&.type).should eq("integer")
    syntax.node_at(8, named: false).try(&.text(subject.buffer)).should eq("2")
  end

  it "serves tokens through scribe's TokenSource" do
    subject = document("[null]")
    source  = TreeSitter::Syntax.new(subject, TreeSitter.language("json")).as(Scribe::TokenSource)
    kinds(source, subject.buffer, 0).should eq([{"null", "constant.builtin"}])
  end
end

describe TreeSitter::Tokenizer do
  it "tokenizes standalone text through scribe's Tokenizer interface" do
    marker = TreeSitter.language("json").tokenizer(Plain.new).as(Scribe::Tokenizer)
    found  = marker.tokens(%({"a": 1}\n[null]))
    found.size.should eq(2)
    found[0].map(&.kind).should contain("string.special.key")
    found[1].map(&.kind).should contain("constant.builtin")
  end

  it "agrees with Syntax on the same text" do
    text   = "def run\n  @x = \"hi\"\nend"
    marker = TreeSitter.language("crystal").tokenizer(Plain.new)
    subject = document(text)
    syntax  = TreeSitter::Syntax.new(subject, TreeSitter.language("crystal"))
    direct  = Array.new(subject.buffer.line_count) { |line| syntax.tokens(subject.buffer, line) }
    marker.tokens(text).should eq(direct)
  end

  it "builds a tokenizer from a path" do
    TreeSitter::Tokenizer.for("src/app.cr", Plain.new).should_not be_nil
    TreeSitter::Tokenizer.for("src/app.cobol", Plain.new).should be_nil
  end
end

describe "TreeSitter::Syntax fold ranges" do
  it "offers every multi-line node as a fold, one per starting line" do
    subject = document("def run(x)\n  if x\n    1\n  end\nend")
    syntax  = TreeSitter::Syntax.new(subject, TreeSitter.language("crystal"))
    found   = syntax.fold_ranges

    found.map(&.first).should eq(found.map(&.first).sort)
    found.map(&.first).uniq.size.should eq(found.size)
    found.should contain({0, 4})
    found.any? { |(first, last)| first == 1 && last >= 3 }.should be_true
  end

  it "drives a view's folds" do
    subject = document("def run\n  1\n  2\nend\nx = 1")
    syntax  = TreeSitter::Syntax.new(subject, TreeSitter.language("crystal"))
    subject.view.folds.replace(syntax.fold_ranges)

    subject.view.folds.empty?.should be_false
    subject.view.folds.collapsed?(0).should be_true
    subject.view.folds.hidden?(1).should be_true
    subject.view.layout.row_count.should be < 5
  end

  it "skips single-line nodes" do
    subject = document(%({"a": 1}))
    syntax  = TreeSitter::Syntax.new(subject, TreeSitter.language("json"))
    syntax.fold_ranges.should be_empty
  end
end
