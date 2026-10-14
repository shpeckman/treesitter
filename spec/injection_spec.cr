# spec/injection_spec.cr
require "./spec_helper"

private def crystal_with(injections : String, locals : String = "") : TreeSitter::Language
  found = TreeSitter.language("crystal")
  found.injections = injections
  found.locals = locals
  found
end

private def python_with(injections : String) : TreeSitter::Language
  found = TreeSitter.language("python")
  found.injections = injections
  found
end

private def reset : Nil
  %w(crystal python).each do |name|
    found = TreeSitter.language(name)
    found.injections = ""
    found.locals = ""
  end
end

describe TreeSitter::Injection do
  it "reads the language from a #set! property" do
    language = crystal_with(%|((string) @injection.content (#set! injection.language "json"))|)
    subject  = document(%(x = "{\\"a\\": 1}"))
    syntax   = TreeSitter::Syntax.new(subject, language)

    syntax.injections.size.should eq(1)
    syntax.injections.first.language.name.should eq("json")
    reset
  end

  it "reads the language from a capture" do
    language = crystal_with(%|((call (identifier) @injection.language (argument_list (string) @injection.content)))|)
    subject  = document(%(json("[1, 2]")))
    syntax   = TreeSitter::Syntax.new(subject, language)

    syntax.injections.map(&.language.name).should eq(["json"])
    reset
  end

  it "styles the injected region with the other grammar's tokens" do
    language = python_with(%|((string (string_content) @injection.content) (#set! injection.language "json"))|)
    subject  = document(%(x = "null"))
    syntax   = TreeSitter::Syntax.new(subject, language)
    found    = syntax.tokens(subject.buffer, 0)

    marked = found.find { |token| token.kind == "constant.builtin" }.not_nil!
    subject.buffer.line(0).slice(marked.start, marked.stop).should eq("null")
    reset
  end

  it "keeps the host tokens outside the region and replaces those inside it" do
    language = python_with(%|((string (string_content) @injection.content) (#set! injection.language "json"))|)
    subject  = document(%(def run():\n  x = "true"\n))
    syntax   = TreeSitter::Syntax.new(subject, language)

    syntax.tokens(subject.buffer, 0).map(&.kind).should contain("keyword")
    inner = syntax.tokens(subject.buffer, 1)
    inner.map(&.kind).should contain("constant.builtin")
    inner.map(&.kind).should_not contain("string")
    reset
  end

  it "places injected tokens at host columns, not region-relative ones" do
    subject = document(%(x = "null"))
    region  = TreeSitter::Region.new(5, 9, 0, 0)
    found   = TreeSitter::Injection.new(TreeSitter.language("json"), region).tokens(subject.buffer, 0)

    found.map { |token| {token.kind, token.start, token.count} }.should eq([{"constant.builtin", 5, 4}])
  end

  it "ignores an unknown language and a self-injection" do
    crystal_with(%|((string) @injection.content (#set! injection.language "cobol"))|)
    subject = document(%(x = "y"))
    TreeSitter::Syntax.new(subject, TreeSitter.language("crystal")).injections.should be_empty

    crystal_with(%|((string) @injection.content (#set! injection.language "crystal"))|)
    other = document(%(x = "y"))
    TreeSitter::Syntax.new(other, TreeSitter.language("crystal")).injections.should be_empty
    reset
  end

  it "has no injections without a query" do
    reset
    subject = document(%(x = "{}"))
    TreeSitter::Syntax.new(subject, TreeSitter.language("crystal")).injections.should be_empty
  end

  it "recollects them after an edit" do
    language = crystal_with(%|((string) @injection.content (#set! injection.language "json"))|)
    subject  = document(%(x = "1"))
    syntax   = TreeSitter::Syntax.new(subject, language)
    syntax.injections.size.should eq(1)

    subject.run(Scribe::Command::DocumentEnd)
    subject.insert(%(\ny = "2"))
    syntax.injections.size.should eq(2)
    reset
  end
end

describe TreeSitter::Locals do
  it "collects definitions, references and scopes" do
    language = crystal_with("", %|
      (block) @local.scope
      (assign (identifier) @local.definition)
      (identifier) @local.reference
    |)
    subject = document("value = 1\nputs value")
    syntax  = TreeSitter::Syntax.new(subject, language)
    scopes  = syntax.locals.not_nil!

    scopes.empty?.should be_false
    scopes.defined?("value").should be_true
    scopes.defined?("missing").should be_false
    reset
  end

  it "refines a token whose text resolves to a local" do
    language = crystal_with("", %|
      (assign (identifier) @local.definition)
      (identifier) @local.reference
    |)
    subject = document("value = 1\nvalue")
    syntax  = TreeSitter::Syntax.new(subject, language)
    scopes  = syntax.locals.not_nil!

    byte = subject.buffer.line_byte(1)
    scopes.local?(byte).should be_true
    scopes.refine("function", byte).should eq("variable")
    scopes.refine("variable.parameter", byte).should eq("variable.parameter")
    scopes.refine("function", byte + 99).should eq("function")
    reset
  end

  it "is nil without a query" do
    reset
    subject = document("x = 1")
    TreeSitter::Syntax.new(subject, TreeSitter.language("crystal")).locals.should be_nil
  end
end
