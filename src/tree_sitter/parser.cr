# src/tree_sitter/parser.cr

module TreeSitter
  # Parses UTF-8 text with one `Language` into a `Tree`. Passing the previous tree, edited with `Tree#edit`, makes
  # the parse incremental. A parser is not safe to share between threads; use one per fiber that parses.
  class Parser
    # The grammar in use.
    getter language : Language

    def initialize(@language : Language)
      @pointer = LibTreeSitter.ts_parser_new
      self.language = @language
    end

    # Switches the grammar; raises `Error` when the library rejects it.
    def language=(language : Language) : Language
      raise Error.new("parser rejected grammar #{language.name}") unless LibTreeSitter.ts_parser_set_language(@pointer, language)
      @language = language
    end

    # Parses *text*, reusing the unchanged parts of *old_tree*.
    def parse(text : String, old_tree : Tree? = nil) : Tree
      tree(LibTreeSitter.ts_parser_parse_string(@pointer, old(old_tree), text, text.bytesize.to_u32))
    end

    # Parses text read in chunks: the block gets a byte offset and returns the bytes from there (any length, an empty
    # slice at the end). Each chunk must stay unchanged until the next call; the parser keeps the last one alive.
    def parse(old_tree : Tree? = nil, &read : Int32 -> Bytes) : Tree
      reader = Reader.new(read)
      input = LibTreeSitter::Input.new(payload: Box.box(reader), encoding: LibTreeSitter::InputEncoding::UTF8,
        decode: Pointer(Void).null,
        read: ->(payload : Void*, byte : UInt32, _point : LibTreeSitter::Point, size : UInt32*) {
          chunk = Box(Reader).unbox(payload).call(byte.to_i)
          size.value = chunk.size.to_u32
          chunk.to_unsafe
        })
      tree(LibTreeSitter.ts_parser_parse(@pointer, old(old_tree), input))
    end

    # The C pointer.
    def to_unsafe : Void*
      @pointer
    end

    def finalize
      LibTreeSitter.ts_parser_delete(@pointer)
    end

    private def old(tree : Tree?) : Void*
      tree ? tree.to_unsafe : Pointer(Void).null
    end

    private def tree(pointer : Void*) : Tree
      raise Error.new("parse did not finish") if pointer.null?
      Tree.new(pointer)
    end

    # Holds the read block and its last chunk, so the chunk's memory outlives the callback.
    private class Reader
      @held = Bytes.empty

      def initialize(@read : Int32 -> Bytes)
      end

      def call(byte : Int32) : Bytes
        @held = @read.call(byte)
      end
    end
  end
end
