# spec/language_spec.cr
require "./spec_helper"

describe TreeSitter::Language do
  it "bundles five grammars whose highlight queries compile" do
    (%w(bash c crystal json python) - TreeSitter.languages.map(&.name)).should be_empty
    TreeSitter.languages.each do |language|
      language.highlights.pattern_count.should be > 0
      language.abi_version.should be >= 14
    end
  end

  it "finds languages by name and by path, with comment tokens" do
    TreeSitter.language("crystal").comment.should eq("#")
    TreeSitter.language("c").comment.should eq("//")
    TreeSitter.language("json").comment.should be_nil
    TreeSitter.language_for("src/app.cr").try(&.name).should eq("crystal")
    TreeSitter.language_for("include/x.h").try(&.name).should eq("c")
    TreeSitter.language_for("README").should be_nil
    TreeSitter.language?("cobol").should be_nil
    expect_raises(TreeSitter::Error, /unknown language 'cobol'/) { TreeSitter.language("cobol") }
  end

  it "lets the host register a language that wins its extensions" do
    json   = TreeSitter.language("json")
    custom = TreeSitter::Language.new("jsonc", json.to_unsafe, ["jsonc", ".json"], comment: "//", highlights: "(string) @string")
    TreeSitter.register(custom)
    TreeSitter.language_for("a.jsonc").should be(custom)
    TreeSitter.language_for("a.json").should be(custom)
    TreeSitter.register(json)
  end

  it "reports where a query is wrong" do
    error = expect_raises(TreeSitter::QueryError) { TreeSitter.language("json").query("(string) @s\n(nope) @x") }
    error.kind.should eq(LibTreeSitter::QueryError::NodeType)
    error.message.should eq("nodetype error in query at line 2, column 2")
  end
end
