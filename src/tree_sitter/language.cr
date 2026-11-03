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

    # Directories searched by `Language.find`, in order. Defaults to the per-user and system library directories;
    # replace or reorder the array to configure lookup.
    class_property directories : Array(String) = [
      File.join(Path.home.to_s, ".local", "lib"),
      "/usr/local/lib",
      "/usr/local/lib64",
      "/usr/lib",
      "/usr/lib64",
    ]

    # Finds the shared library for grammar *name* in `directories`, looking for `libtree-sitter-<name>.so` and
    # `<name>.so` in each directory; returns its path, or `nil` when no library exists.
    def self.find(name : String) : String?
      directories.each do |directory|
        {"libtree-sitter-#{name}.so", "#{name}.so"}.each do |filename|
          path = File.join(directory, filename)
          return path if File.file?(path)
        end
      end
      nil
    end

    # Finds and loads grammar *name* from `directories`; raises `Error` when no matching shared library exists.
    def self.load(name : String) : Language
      path = find(name) || raise Error.new("cannot find grammar #{name}; searched: #{directories.join(", ")}")
      load(path, name)
    end

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

    # :nodoc:
    def to_unsafe : Void*
      @pointer
    end

    private def self.dl_error : String
      message = LibC.dlerror
      message.null? ? "unknown error" : String.new(message)
    end
  end
end
