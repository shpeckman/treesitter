# src/tree_sitter/error.cr

module TreeSitter
  # Raised when a grammar cannot be loaded, is of an unsupported ABI version, or a parse cannot start.
  class Error < Exception
  end

  # Raised by `Query.new` for a query the grammar rejects, with the byte `offset` into the source and the `kind` of
  # problem.
  class QueryError < Error
    # What is wrong with the query at `offset`.
    enum Kind
      Syntax    = 1
      NodeType
      Field
      Capture
      Structure
      Language
    end

    # Byte offset of the problem in the query source.
    getter offset : Int32
    # The kind of problem.
    getter kind : Kind

    def initialize(@offset : Int32, @kind : Kind, source : String)
      line = source.byte_slice(0, @offset).count('\n') + 1
      super("#{@kind} error in query at byte #{@offset} (line #{line})")
    end
  end
end
