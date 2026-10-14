# src/treesitter/painter.cr
module TreeSitter
  class Painter
    record Paint, from : Int32, to : Int32, span : Int32, pattern : Int32, capture : Int32

    getter query : Query

    @paints : Array(Paint)
    @kinds  : Array(Int32)
    @later  : Bool

    def initialize(@query : Query, precedence : Precedence = Precedence::Last)
      @paints = [] of Paint
      @kinds  = [] of Int32
      @later  = precedence.last?
    end

    def paint(root : Node, buffer : Scribe::Buffer, line : Int32) : Array(Scribe::Token)
      row  = buffer.line(line)
      size = row.bytesize
      return Scribe::TokenSource::NO_TOKENS if size == 0

      start = buffer.line_byte(line)
      @paints.clear
      @query.each_capture(root, buffer, start, start + size) do |capture|
        next if capture.name.starts_with?('_')

        from = capture.node.start_byte - start
        to   = capture.node.end_byte - start
        @paints << Paint.new(from.clamp(0, size), to.clamp(0, size), to - from, capture.pattern, capture.index) if from < size && to > 0
      end
      return Scribe::TokenSource::NO_TOKENS if @paints.empty?

      later = @later
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

    private def runs(row : Scribe::Line, kinds : Array(Int32)) : Array(Scribe::Token)
      tokens  = [] of Scribe::Token
      current = -1
      first   = 0
      row.size.times do |column|
        kind = kinds.unsafe_fetch(row.marks.unsafe_fetch(column))
        next if kind == current

        tokens << Scribe::Token.new(first, column - first, @query.names[current]) if current >= 0
        current = kind
        first   = column
      end
      tokens << Scribe::Token.new(first, row.size - first, @query.names[current]) if current >= 0
      tokens
    end
  end
end
