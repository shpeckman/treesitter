# src/treesitter/parser.cr
module TreeSitter
  class Parser
    READ = ->(payload : Void*, byte : UInt32, _point : LibTreeSitter::Point, read : UInt32*) do
      piece = Box(Scribe::Buffer).unbox(payload).chunk(byte.to_i32)
      read.value = piece.size.to_u32
      piece.to_unsafe
    end

    getter language : Language

    def initialize(@language : Language)
      @raw = LibTreeSitter.ts_parser_new
      assign(@language)
    end

    def finalize
      LibTreeSitter.ts_parser_delete(@raw)
    end

    def language=(language : Language) : Language
      assign(language)
      @language = language
    end

    def parse(text : String, old : Tree? = nil) : Tree
      tree = LibTreeSitter.ts_parser_parse_string(@raw, old.try(&.to_unsafe) || Pointer(Void).null, text, text.bytesize.to_u32)
      raise Error.new("tree-sitter could not parse the #{@language.name} text") if tree.null?

      Tree.new(tree)
    end

    def parse(buffer : Scribe::Buffer, old : Tree? = nil) : Tree
      box   = Box.box(buffer)
      input = LibTreeSitter::Input.new(payload: box, read: READ, encoding: LibTreeSitter::InputEncoding::UTF8, decode: Pointer(Void).null)
      tree  = LibTreeSitter.ts_parser_parse(@raw, old.try(&.to_unsafe) || Pointer(Void).null, input)
      raise Error.new("tree-sitter could not parse the #{@language.name} text") if tree.null?

      Tree.new(tree)
    end

    private def assign(language : Language) : Nil
      return if LibTreeSitter.ts_parser_set_language(@raw, language)

      raise Error.new("#{language.name} uses tree-sitter ABI #{language.abi_version}, which this runtime does not support")
    end
  end
end
