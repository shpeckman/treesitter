# spec/query_spec.cr
require "./spec_helper"

private def names(query : TreeSitter::Query, text : String) : Array({String, String})
  tree = query.language.parse(text)
  query.captures(tree.root, text).map { |capture| {capture.name, capture.node.text(text)} }
end

describe TreeSitter::Query do
  it "applies eq, not-eq, match, not-match, any-of and not-any-of" do
    json = TreeSitter.language("json")
    text = %(["ab", "cd", "AB", "x"])
    names(json.query(%|((string_content) @hit (#eq? @hit "cd"))|), text).should eq([{"hit", "cd"}])
    names(json.query(%|((string_content) @hit (#not-eq? @hit "cd"))|), text).map(&.[1]).should eq(%w(ab AB x))
    names(json.query(%|((string_content) @hit (#match? @hit "^[A-Z]+$"))|), text).map(&.[1]).should eq(%w(AB))
    names(json.query(%|((string_content) @hit (#not-match? @hit "^[a-z]"))|), text).map(&.[1]).should eq(%w(AB))
    names(json.query(%|((string_content) @hit (#any-of? @hit "x" "ab"))|), text).map(&.[1]).should eq(%w(ab x))
    names(json.query(%|((string_content) @hit (#not-any-of? @hit "x" "ab"))|), text).map(&.[1]).should eq(%w(cd AB))
  end

  it "compares two captures with eq" do
    json  = TreeSitter.language("json")
    query = json.query(%|((pair key: (string (string_content) @key) value: (string (string_content) @value)) (#eq? @key @value))|)
    names(query, %({"a": "a", "b": "c"})).should eq([{"key", "a"}, {"value", "a"}])
  end

  it "limits matches to a byte range and reads predicates from a buffer" do
    json   = TreeSitter.language("json")
    buffer = Scribe::Buffer.new(Plain.new, %(["A",\n "b",\n "C"]))
    tree   = json.parser.parse(buffer)
    query  = json.query(%|((string_content) @up (#match? @up "^[A-Z]$"))|)
    query.captures(tree.root, buffer).map(&.node.text(buffer)).should eq(%w(A C))
    query.captures(tree.root, buffer, buffer.line_byte(2), buffer.bytesize).map(&.node.text(buffer)).should eq(%w(C))
  end

  it "ignores predicates it does not know" do
    json = TreeSitter.language("json")
    names(json.query(%|((number) @n (#set! priority 1))|), "[1]").should eq([{"n", "1"}])
  end
end
