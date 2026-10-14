# src/treesitter/syntax.cr
module TreeSitter
  class Syntax
    include Scribe::Listener
    include Scribe::TokenSource

    getter document : Scribe::Document
    getter language : Language
    getter query    : Query

    @painter    : Painter
    @parser     : Parser
    @tree       : Tree
    @stale      : Bool
    @lines      : Array(Array(Scribe::Token)?)
    @stop       : Proc(Nil)?
    @injections : Array(Injection)?
    @locals     : Locals?

    def self.for(document : Scribe::Document, path : String) : Syntax?
      TreeSitter.language_for(path).try { |language| new(document, language) }
    end

    def initialize(@document : Scribe::Document, @language : Language, query : Query? = nil)
      @query   = query || @language.highlights
      @painter = Painter.new(@query, @language.precedence)
      @parser  = Parser.new(@language)
      @tree    = @parser.parse(@document.buffer)
      @stale   = false
      @lines      = Array(Array(Scribe::Token)?).new(@document.buffer.line_count, nil)
      @injections = nil
      @locals     = nil
      @stop       = @document.listen(self)
    end

    def injections : Array(Injection)
      refresh
      @injections ||= Injection.collect(@language, @tree.root, @document.buffer)
    end

    def locals : Locals?
      refresh
      found = @locals
      return found if found

      query = @language.locals? || return nil
      @locals = Locals.new(query, @tree.root, @document.buffer)
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

      @lines[line] ||= paint(buffer, line)
    end

    private def paint(buffer : Scribe::Buffer, line : Int32) : Array(Scribe::Token)
      found = @painter.paint(@tree.root, buffer, line)
      found = refine(found, buffer, line)
      nested = injections
      return found if nested.empty?

      from = buffer.line_byte(line)
      to   = from + buffer.line(line).bytesize
      nested.each do |injection|
        next unless injection.covers?(from, to)

        found = merge(found, injection.tokens(buffer, line))
      end
      found
    end

    private def refine(found : Array(Scribe::Token), buffer : Scribe::Buffer, line : Int32) : Array(Scribe::Token)
      scopes = locals || return found
      start  = buffer.line_byte(line)
      row    = buffer.line(line)

      found.map do |token|
        kind = scopes.refine(token.kind, start + row.boundary(token.start))
        kind == token.kind ? token : Scribe::Token.new(token.start, token.count, kind)
      end
    end

    private def merge(host : Array(Scribe::Token), nested : Array(Scribe::Token)) : Array(Scribe::Token)
      return host if nested.empty?

      kept = host.reject do |token|
        nested.any? { |inner| inner.start < token.stop && token.start < inner.stop }
      end
      (kept + nested).sort_by!(&.start)
    end

    def fold_ranges(minimum : Int32 = 1) : Array({Int32, Int32})
      found = {} of Int32 => Int32
      stack = [root]

      while node = stack.pop?
        node.named_children.each do |child|
          first = child.start_point.line
          last  = child.end_point.line
          last -= 1 if child.end_point.column == 0 && last > first
          found[first] = last if last - first >= minimum && (found[first]? || first) < last
          stack << child
        end
      end

      found.keys.sort.map { |first| {first, found[first]} }
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
      @tree       = fresh
      @stale      = false
      @injections = nil
      @locals     = nil
    end
  end
end
