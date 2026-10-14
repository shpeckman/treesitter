# spec/tree_spec.cr
require "./spec_helper"

describe TreeSitter::Parser do
  it "parses a string and a buffer to the same tree" do
    text   = %({"a": [1, "é👍"],\n "b": null})
    parser = TreeSitter.language("json").parser
    parser.parse(text).to_s.should eq(parser.parse(Scribe::Buffer.new(Plain.new, text)).to_s)
    parser.parse(text).to_s.should eq("(document (object (pair key: (string (string_content)) value: (array (number) (string (string_content)))) (pair key: (string (string_content)) value: (null))))")
  end

  it "walks nodes with byte ranges, points, fields and text" do
    text = "x = [1, 2]\n"
    tree = TreeSitter.language("python").parse(text)
    root = tree.root
    root.type.should eq("module")
    root.has_error?.should be_false
    assignment = root.named_child(0).not_nil!
    assignment.type.should eq("assignment")
    assignment.field("left").try(&.text(text)).should eq("x")
    right = assignment.field("right").not_nil!
    right.bytes.should eq(4...10)
    right.end_point.should eq(Scribe::Point.new(0, 10))
    right.named_children.map(&.text(text)).should eq(%w(1 2))
    right.children.size.should eq(5)
    right.parent.try(&.type).should eq("assignment")
    root.descendant(8).try(&.text(text)).should eq("2")
    root.parent.should be_nil
  end

  it "marks syntax errors" do
    TreeSitter.language("json").parse(%({"a": })).root.has_error?.should be_true
  end

  it "reparses incrementally after an edit and reports what changed" do
    subject = document("[1, 2]")
    parser  = TreeSitter.language("json").parser
    old     = parser.parse(subject.buffer)
    subject.buffer.on_change { |change| old.edit(change, subject.buffer) }
    subject.select_range(5, 5)
    subject.insert(", \"x\"")
    fresh = parser.parse(subject.buffer, old)
    fresh.to_s.should eq(parser.parse(subject.value).to_s)
    old.changed_ranges(fresh).should_not be_empty
  end
end
