# spec/spec_helper.cr

require "spec"
require "../src/fixture"

JSON_GRAMMAR = TreeSitter::Fixture.language("json")

Spec.after_suite { TreeSitter::Fixture.clean }

# The node types along the named spine of *node*: itself and its named children, depth first.
def types(node : TreeSitter::Node) : Array(String)
  found = [node.type]
  node.each_named_child { |child| found.concat(types(child)) }
  found
end
