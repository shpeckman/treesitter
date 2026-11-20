require "./spec_helper"

TREE_GRAMMAR = TreeSitter::Fixture.language("tree")

describe "tree grammar" do
  it "parses entries, guides, paths, and descriptions" do
    text = ".\n├─╴src/\n│  ├─╴apprt.cr                  entry point\n╰─╴test/"
    root = TreeSitter::Parser.new(TREE_GRAMMAR).parse(text).root
    root.has_error?.should be_false
    types(root).should eq(%w(document root entry branch directory entry guide branch file description entry branch directory))
    entry = root.named_child(2).not_nil!
    path = entry.field("path").not_nil!
    description = entry.field("description").not_nil!
    text.byte_slice(path.start_byte, path.end_byte - path.start_byte).should eq("apprt.cr")
    text.byte_slice(description.start_byte, description.end_byte - description.start_byte).should eq("entry point")
  end

  it "parses abbreviated file ranges with endpoints" do
    text = "├─╴adw … pango.cr      generated files"
    root = TreeSitter::Parser.new(TREE_GRAMMAR).parse(text).root
    root.has_error?.should be_false
    abbreviation = root.named_child(0).not_nil!.field("path").not_nil!
    abbreviation.type.should eq("abbreviation")
    from = abbreviation.field("from").not_nil!
    to = abbreviation.field("to").not_nil!
    text.byte_slice(from.start_byte, from.end_byte - from.start_byte).should eq("adw")
    text.byte_slice(to.start_byte, to.end_byte - to.start_byte).should eq("pango.cr")
  end

  it "parses the full bundled listing" do
    path = File.join(TreeSitter::Fixture::SOURCES, "tree", "examples", "basic.tree")
    root = TreeSitter::Parser.new(TREE_GRAMMAR).parse(File.read(path)).root
    root.has_error?.should be_false
    root.named_child_count.should eq(90)
  end

  it "supports highlight queries" do
    text = ".\n├─╴src/\n│  ├─╴apprt.cr                  entry point"
    root = TreeSitter::Parser.new(TREE_GRAMMAR).parse(text).root
    source = File.read(File.join(TreeSitter::Fixture::SOURCES, "tree", "queries", "highlights.scm"))
    query = TreeSitter::Query.new(TREE_GRAMMAR, source)
    found = [] of {String, String}
    query.each_capture(root, text) do |capture|
      found << {capture.name, text.byte_slice(capture.node.start_byte, capture.node.end_byte - capture.node.start_byte)}
    end
    found.should contain({"constant", "."})
    found.should contain({"type", "src/"})
    found.should contain({"punctuation.delimiter", "│"})
    found.should contain({"function", "apprt.cr"})
    found.should contain({"comment", "entry point"})
  end
end
