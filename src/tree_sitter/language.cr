# src/tree_sitter/language.cr

module TreeSitter
  # A grammar: the parse tables a `Parser` uses. Load one from a shared library with `Language.load`, or wrap the
  # pointer a linked `tree_sitter_<name>` function returns. Loaded libraries stay open for the life of the process.
  class Language
    # Oldest grammar ABI version this library parses.
    MIN_ABI = 13
    # Newest grammar ABI version this library parses.
    MAX_ABI = 15

    # The name given when loading, if any.
    getter name : String?

    # Wraps *pointer*, the result of a grammar's `tree_sitter_<name>()`; raises `Error` for a null pointer or an
    # unsupported ABI version.
    def initialize(@pointer : Void*, @name : String? = nil)
      raise Error.new("null grammar #{@name}") if @pointer.null?
      abi = abi_version
      raise Error.new("grammar #{@name} has ABI #{abi}, supported: #{MIN_ABI}..#{MAX_ABI}") unless MIN_ABI <= abi <= MAX_ABI
    end

    # Opens the shared library at *path* and calls its *symbol* (by default `tree_sitter_<name>`, dashes as
    # underscores); raises `Error` when the library or the symbol is missing.
    def self.load(path : String, name : String, symbol : String = "tree_sitter_#{name.tr("-", "_")}") : Language
      handle = LibC.dlopen(path, LibC::RTLD_NOW | LibC::RTLD_LOCAL)
      raise Error.new("cannot open #{path}: #{dl_error}") if handle.null?
      entry = LibC.dlsym(handle, symbol)
      raise Error.new("#{path} has no #{symbol}: #{dl_error}") if entry.null?
      new(Proc(Void*).new(entry, Pointer(Void).null).call, name)
    end

    # The grammar's ABI version.
    def abi_version : Int32
      LibTreeSitter.ts_language_abi_version(@pointer).to_i
    end

    # The C pointer.
    def to_unsafe : Void*
      @pointer
    end

    private def self.dl_error : String
      message = LibC.dlerror
      message.null? ? "unknown error" : String.new(message)
    end
  end
end
