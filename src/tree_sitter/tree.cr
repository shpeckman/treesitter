# src/tree_sitter/tree.cr

module TreeSitter
  # A syntax tree made by `Parser#parse`. Edit it with `edit` before passing it back to `parse` as the old tree, so
  # unchanged parts are reused. Freed when collected; the `Node`s taken from it keep it alive.
  class Tree
    def initialize(@pointer : Void*)
    end

    # The root node.
    def root : Node
      Node.new(LibTreeSitter.ts_tree_root_node(@pointer), self)
    end

    # Adjusts the tree's positions for *edit*, which already happened to the text.
    def edit(edit : Edit) : Nil
      raw = edit.to_lib
      LibTreeSitter.ts_tree_edit(@pointer, pointerof(raw))
    end

    # An independent copy, cheap to make, for use on another fiber or as a snapshot.
    def copy : Tree
      Tree.new(LibTreeSitter.ts_tree_copy(@pointer))
    end

    # The C pointer.
    def to_unsafe : Void*
      @pointer
    end

    def finalize
      LibTreeSitter.ts_tree_delete(@pointer)
    end
  end
end
