# spec/tree_sitter_spec.cr

require "./spec_helper"

describe TreeSitter::Language do
  it "loads a grammar and reports its ABI" do
    JSON_GRAMMAR.name.should eq("json")
    JSON_GRAMMAR.abi_version.should eq(14)
  end

  it "raises for a missing library" do
    expect_raises(TreeSitter::Error, /cannot open/) { TreeSitter::Language.load("/nonexistent/json.so", "json") }
  end

  it "raises for a missing symbol" do
    expect_raises(TreeSitter::Error, /has no tree_sitter_yaml/) do
      TreeSitter::Language.load(TreeSitter::Fixture.library("json"), "yaml")
    end
  end
end

describe TreeSitter::Parser do
  it "parses a string into named nodes with ranges and points" do
    tree = TreeSitter::Parser.new(JSON_GRAMMAR).parse(%({"a": [1, true]}))
    root = tree.root
    root.type.should eq("document")
    types(root).should eq(%w(document object pair string string_content array number true))
    pair = root.named_child(0).not_nil!.named_child(0).not_nil!
    pair.field("key").not_nil!.range.should eq(1...4)
    array = pair.field("value").not_nil!
    array.start_point.should eq(TreeSitter::Point.new(0, 6))
    array.child(0).not_nil!.named?.should be_false
    array.named_child(1).not_nil!.previous_named_sibling.not_nil!.type.should eq("number")
    array.parent.not_nil!.should eq(pair)
    root.has_error?.should be_false
  end

  it "parses from a chunked reader" do
    lines = ["[1,", "\n", " 2]"]
    starts = [0, 3, 4]
    tree = TreeSitter::Parser.new(JSON_GRAMMAR).parse do |byte|
      index = starts.rindex { |start| start <= byte }
      next Bytes.empty unless index && byte < 7
      lines[index].to_slice[byte - starts[index]..]
    end
    array = tree.root.named_child(0).not_nil!
    array.named_child(1).not_nil!.start_point.should eq(TreeSitter::Point.new(1, 1))
  end

  it "reparses incrementally after an edit" do
    parser = TreeSitter::Parser.new(JSON_GRAMMAR)
    tree = parser.parse("[1, 2]")
    tree.edit(TreeSitter::Edit.new(start_byte: 5, old_end_byte: 5, new_end_byte: 8,
      start_point: TreeSitter::Point.new(0, 5), old_end_point: TreeSitter::Point.new(0, 5),
      new_end_point: TreeSitter::Point.new(0, 8)))
    fresh = parser.parse("[1, 2, 3]", tree)
    types(fresh.root).should eq(%w(document array number number number))
  end

  it "marks errors and missing nodes" do
    root = TreeSitter::Parser.new(JSON_GRAMMAR).parse("[1, 2").root
    root.has_error?.should be_true
    array = root.named_child(0).not_nil!
    array.child(array.child_count - 1).not_nil!.missing?.should be_true
  end

  it "finds the smallest node spanning a byte range" do
    root = TreeSitter::Parser.new(JSON_GRAMMAR).parse("[10, 20]").root
    root.named_descendant(6, 6).not_nil!.range.should eq(5...7)
    root.descendant(3, 3).not_nil!.type.should eq(",")
  end
end

describe TreeSitter::Query do
  it "yields captures in text order" do
    text = %({"a": 1, "b": null})
    root = TreeSitter::Parser.new(JSON_GRAMMAR).parse(text).root
    query = TreeSitter::Query.new(JSON_GRAMMAR, "(pair key: (string) @key) (number) @number (null) @constant")
    found = [] of {String, String}
    query.each_capture(root, text) { |capture| found << {capture.name, text.byte_slice(capture.node.start_byte, capture.node.end_byte - capture.node.start_byte)} }
    found.should eq([{"key", %("a")}, {"number", "1"}, {"key", %("b")}, {"constant", "null"}])
  end

  it "limits captures to a byte range" do
    text = "[1, 2, 3]"
    root = TreeSitter::Parser.new(JSON_GRAMMAR).parse(text).root
    query = TreeSitter::Query.new(JSON_GRAMMAR, "(number) @number")
    found = [] of Int32
    query.each_capture(root, text, 3...6) { |capture| found << capture.node.start_byte }
    found.should eq([4])
  end

  it "applies eq, match, any-of and their negations" do
    text = %(["if", "else", "x1", "y"])
    root = TreeSitter::Parser.new(JSON_GRAMMAR).parse(text).root
    query = TreeSitter::Query.new(JSON_GRAMMAR, <<-SCM)
      ((string (string_content) @eq) (#eq? @eq "if"))
      ((string (string_content) @any) (#any-of? @any "if" "else"))
      ((string (string_content) @digit) (#match? @digit "[0-9]"))
      ((string (string_content) @lua) (#lua-match? @lua "^%a%d$"))
      ((string (string_content) @plain) (#not-match? @plain "[0-9]") (#not-any-of? @plain "if" "else"))
      ((string (string_content) @tagged) (#set! priority 105))
      SCM
    found = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
    query.each_capture(root, text) do |capture|
      found[capture.name] << text.byte_slice(capture.node.start_byte, capture.node.end_byte - capture.node.start_byte)
    end
    found["eq"].should eq(["if"])
    found["any"].should eq(["if", "else"])
    found["digit"].should eq(["x1"])
    found["lua"].should eq(["x1"])
    found["plain"].should eq(["y"])
    found["tagged"].size.should eq(4)
  end

  it "compares two captures with eq" do
    text = %({"a": "a", "b": "c"})
    root = TreeSitter::Parser.new(JSON_GRAMMAR).parse(text).root
    query = TreeSitter::Query.new(JSON_GRAMMAR, "((pair key: (string) @key value: (string) @value) (#eq? @key @value))")
    matches = [] of TreeSitter::Match
    query.each_match(root, text) { |match| matches << match }
    matches.size.should eq(1)
    matches.first["key"].not_nil!.range.should eq(1...4)
    matches.first.nodes("value").size.should eq(1)
  end

  it "raises a query error with its kind and offset" do
    error = expect_raises(TreeSitter::QueryError) { TreeSitter::Query.new(JSON_GRAMMAR, "(number) @n\n(nonsense) @x") }
    error.kind.should eq(TreeSitter::QueryError::Kind::NodeType)
    error.offset.should eq(13)
    error.message.not_nil!.should contain("line 2")
  end

  it "translates Lua patterns" do
    TreeSitter::Predicate.lua("^%u[%w_]-$").should eq("^[A-Z][A-Za-z0-9_]*?$")
    TreeSitter::Predicate.lua("%.%S").should eq("\\.[^\\s]")
  end
end
