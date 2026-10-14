# src/treesitter/syntax.cr
module TreeSitter
  class Syntax
    include Scribe::Listener
    include Scribe::TokenSource

    NONE = [] of Scribe::Highlighter::Token

    record Paint, from : Int32, to : Int32, span : Int32, pattern : Int32, capture : Int32

    getter document : Scribe::Document
    getter language : Language
    getter query    : Query

    @parser  : Parser
    @tree    : Tree
    @stale   : Bool
    @lines   : Array(Array(Scribe::Highlighter::Token)?)
    @paints  : Array(Paint)
    @kinds   : Array(Int32)
    @stop    : Proc(Nil)?

    def self.for(document : Scribe::Document, path : String) : Syntax?
      TreeSitter.language_for(path).try { |language| new(document, language) }
    end

    def initialize(@document : Scribe::Document, @language : Language, query : Query? = nil)
      @query  = query || @language.highlights
      @parser = Parser.new(@language)
      @tree   = @parser.parse(@document.buffer)
      @stale  = false
      @lines  = Array(Array(Scribe::Highlighter::Token)?).new(@document.buffer.line_count, nil)
      @paints = [] of Paint
      @kinds  = [] of Int32
      @stop   = @document.listen(self)
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

    def tokens(buffer : Scribe::Buffer, line : Int32) : Array(Scribe::Highlighter::Token)
      refresh
      return NONE unless 0 <= line < @lines.size

      @lines[line] ||= paint(buffer, line)
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
      @lines[line..stop] = Array(Array(Scribe::Highlighter::Token)?).new(change.inserted_lines + 1, nil) if line < @lines.size
    end

    private def refresh : Nil
      return unless @stale

      fresh  = @parser.parse(@document.buffer, @tree)
      @tree.changed_ranges(fresh).each do |region|
        last = Math.min(region.last_row, @lines.size - 1)
        (region.first_row..last).each { |row| @lines[row] = nil }
      end
      @tree  = fresh
      @stale = false
    end

    private def paint(buffer : Scribe::Buffer, line : Int32) : Array(Scribe::Highlighter::Token)
      row   = buffer.line(line)
      size  = row.bytesize
      return NONE if size == 0

      start = buffer.line_byte(line)
      @paints.clear
      @query.each_capture(@tree.root, buffer, start, start + size) do |capture|
        next if capture.name.starts_with?('_')

        from = capture.node.start_byte - start
        to   = capture.node.end_byte - start
        @paints << Paint.new(from.clamp(0, size), to.clamp(0, size), to - from, capture.pattern, capture.index) if from < size && to > 0
      end
      return NONE if @paints.empty?

      later = @language.precedence.last?
      @paints.sort! do |left, right|
        wider = right.span <=> left.span
        next wider unless wider == 0

        later ? left.pattern <=> right.pattern : right.pattern <=> left.pattern
      end
      kinds = @kinds
      kinds.clear
      size.times { kinds << -1 }
      @paints.each do |entry|
        (entry.from...entry.to).each { |byte| kinds.unsafe_put(byte, entry.capture) }
      end
      runs(row, kinds)
    end

    private def runs(row : Scribe::Line, kinds : Array(Int32)) : Array(Scribe::Highlighter::Token)
      tokens  = [] of Scribe::Highlighter::Token
      current = -1
      first   = 0
      row.size.times do |column|
        kind = kinds.unsafe_fetch(row.marks.unsafe_fetch(column))
        next if kind == current

        tokens << Scribe::Highlighter::Token.new(first, column - first, @query.names[current]) if current >= 0
        current = kind
        first   = column
      end
      tokens << Scribe::Highlighter::Token.new(first, row.size - first, @query.names[current]) if current >= 0
      tokens
    end
  end
end
