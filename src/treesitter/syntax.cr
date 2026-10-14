# src/treesitter/syntax.cr
module TreeSitter
  class Syntax
    include Scribe::Listener
    include Scribe::TokenSource

    getter document : Scribe::Document
    getter language : Language
    getter query    : Query

    @painter : Painter
    @parser  : Parser
    @tree    : Tree
    @stale   : Bool
    @lines   : Array(Array(Scribe::Token)?)
    @stop    : Proc(Nil)?

    def self.for(document : Scribe::Document, path : String) : Syntax?
      TreeSitter.language_for(path).try { |language| new(document, language) }
    end

    def initialize(@document : Scribe::Document, @language : Language, query : Query? = nil)
      @query   = query || @language.highlights
      @painter = Painter.new(@query, @language.precedence)
      @parser  = Parser.new(@language)
      @tree    = @parser.parse(@document.buffer)
      @stale   = false
      @lines   = Array(Array(Scribe::Token)?).new(@document.buffer.line_count, nil)
      @stop    = @document.listen(self)
    end

    def close : Nil
      @stop.try(&.call)
      @stop = nil
    end

    def tree : Tree
      refresh
      @tree
    end

    def root : Node
      tree.root
    end

    def tokens(buffer : Scribe::Buffer, line : Int32) : Array(Scribe::Token)
      refresh
      return Scribe::TokenSource::NO_TOKENS unless 0 <= line < @lines.size

      @lines[line] ||= @painter.paint(@tree.root, buffer, line)
    end

    def node_at(offset : Int32, named : Bool = true) : Node?
      byte = @document.buffer.byte_offset(offset)
      root.descendant(byte, byte, named)
    end

    def applied(document : Scribe::Document, change : Scribe::Change) : Nil
      buffer = document.buffer
      @tree.edit(change, buffer)
      @stale = true

      line = buffer.position(change.from).line
      stop = Math.min(line + change.removed_lines, @lines.size - 1)
      @lines[line..stop] = Array(Array(Scribe::Token)?).new(change.inserted_lines + 1, nil) if line < @lines.size
    end

    private def refresh : Nil
      return unless @stale

      fresh = @parser.parse(@document.buffer, @tree)
      @tree.changed_ranges(fresh).each do |region|
        last = Math.min(region.last_row, @lines.size - 1)
        (region.first_row..last).each { |row| @lines[row] = nil }
      end
      @tree  = fresh
      @stale = false
    end
  end
end
