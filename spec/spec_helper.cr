# spec/spec_helper.cr

require "spec"
require "../src/fixture"

JSON_GRAMMAR = TreeSitter::Fixture.language("json")

Spec.after_suite { TreeSitter::Fixture.clean }

# The node types along the named spine of *node*: itself and its named children, depth first.
def types(node : TreeSitter::Node) : Array(String)
  found = [node.type]
  node.named_child_count.times { |index| found.concat(types(node.named_child(index).not_nil!)) }
  found
end
