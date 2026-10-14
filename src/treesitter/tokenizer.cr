# src/treesitter/tokenizer.cr
module TreeSitter
  class Tokenizer
    include Scribe::Tokenizer

    getter language  : Language
    getter query     : Query
    getter graphemes : Scribe::Graphemes

    @painter : Painter
    @parser  : Parser

    def self.for(path : String, graphemes : Scribe::Graphemes) : Tokenizer?
      TreeSitter.language_for(path).try { |language| new(language, graphemes) }
    end

    def initialize(@language : Language, @graphemes : Scribe::Graphemes, query : Query? = nil)
      @query   = query || @language.highlights
      @painter = Painter.new(@query, @language.precedence)
      @parser  = Parser.new(@language)
    end

    def tokens(text : String) : Array(Array(Scribe::Token))
      buffer = Scribe::Buffer.new(@graphemes, text)
      root   = @parser.parse(buffer).root
      Array(Array(Scribe::Token)).new(buffer.line_count) { |line| @painter.paint(root, buffer, line) }
    end
  end
end
