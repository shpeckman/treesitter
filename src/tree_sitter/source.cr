# src/tree_sitter/source.cr

module TreeSitter
  # Where a `Query` reads node text for its predicates: anything that returns the text between two byte offsets.
  # Text kept in another structure (a rope, a line buffer) includes this instead of building one string.
  module Source
    # The text from byte *from* to byte *to* (exclusive).
    abstract def text(from : Int32, to : Int32) : String
  end

  # A `Source` over one string.
  struct StringSource
    include Source

    def initialize(@string : String)
    end

    # The bytes *from*...*to* of the string.
    def text(from : Int32, to : Int32) : String
      @string.byte_slice(from, to - from)
    end
  end
end
