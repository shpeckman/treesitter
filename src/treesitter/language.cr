# src/treesitter/language.cr
module TreeSitter
  enum Precedence
    Last
    First
  end

  class Language
    getter name       : String
    getter extensions : Array(String)
    getter comment    : String?
    getter source     : String
    getter precedence : Precedence

    @highlights : Query?

    def initialize(@name : String, @raw : LibTreeSitter::TSLanguage, extensions : Enumerable(String) = [] of String,
                   *, @comment : String? = nil, highlights : String = "", @precedence : Precedence = Precedence::Last)
      @extensions = extensions.map { |extension| extension.starts_with?('.') ? extension : ".#{extension}" }.to_a
      @source     = highlights
      @highlights = nil
    end

    def to_unsafe : LibTreeSitter::TSLanguage
      @raw
    end

    def abi_version : Int32
      LibTreeSitter.ts_language_abi_version(@raw).to_i32
    end

    def highlights : Query
      @highlights ||= Query.new(self, @source)
    end

    def query(source : String) : Query
      Query.new(self, source)
    end

    def parser : Parser
      Parser.new(self)
    end

    def tokenizer(graphemes : Scribe::Graphemes, query : Query? = nil) : Tokenizer
      Tokenizer.new(self, graphemes, query)
    end

    def parse(text : String) : Tree
      parser.parse(text)
    end

    def inspect(io : IO) : Nil
      io << "#<TreeSitter::Language " << @name << '>'
    end
  end

  macro highlights(name)
    {{ read_file("#{__DIR__.id}/../../queries/#{name.id}/highlights.scm") }}
  end

  @@languages : Hash(String, Language) = {
    "bash"    => Language.new("bash", LibTreeSitter.tree_sitter_bash, %w(.sh .bash), comment: "#", highlights: highlights(bash)),
    "c"       => Language.new("c", LibTreeSitter.tree_sitter_c, %w(.c .h), comment: "//", highlights: highlights(c)),
    "crystal" => Language.new("crystal", LibTreeSitter.tree_sitter_crystal, %w(.cr), comment: "#", highlights: highlights(crystal)),
    "json"    => Language.new("json", LibTreeSitter.tree_sitter_json, %w(.json), highlights: highlights(json), precedence: Precedence::First),
    "python"  => Language.new("python", LibTreeSitter.tree_sitter_python, %w(.py .pyi), comment: "#", highlights: highlights(python)),
  }

  def self.languages : Array(Language)
    @@languages.values
  end

  def self.register(language : Language) : Language
    @@languages[language.name] = language
  end

  def self.language(name : String) : Language
    @@languages[name]? || raise Error.new("unknown language '#{name}' (known: #{@@languages.keys.sort.join(", ")})")
  end

  def self.language?(name : String) : Language?
    @@languages[name]?
  end

  def self.language_for(path : String) : Language?
    extension = File.extname(path)
    return nil if extension.empty?

    @@languages.values.reverse_each.find(&.extensions.includes?(extension))
  end
end
