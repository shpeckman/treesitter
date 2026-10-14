# src/treesitter/injection.cr
module TreeSitter
  class Injection
    CONTENT  = "injection.content"
    LANGUAGE = "injection.language"
    SETTING  = "injection.language"

    getter language : Language
    getter region   : Region

    @painter : Painter
    @parser  : Parser
    @tree    : Tree?

    def initialize(@language : Language, @region : Region, query : Query? = nil)
      found    = query || @language.highlights
      @painter = Painter.new(found, @language.precedence)
      @parser  = Parser.new(@language)
      @parser.included_ranges = [@region]
      @tree    = nil
    end

    def covers?(from : Int32, to : Int32) : Bool
      @region.start_byte < to && from < @region.end_byte
    end

    def tokens(buffer : Scribe::Buffer, line : Int32) : Array(Scribe::Token)
      tree = @tree ||= @parser.parse(buffer)
      @painter.paint(tree.root, buffer, line)
    end

    def self.collect(language : Language, root : Node, buffer : Scribe::Buffer) : Array(Injection)
      query = language.injections? || return [] of Injection
      found = [] of Injection

      query.each_match(root, buffer) do |pattern, captures|
        name    = query.properties(pattern)[SETTING]?
        content = nil.as(Node?)

        captures.each do |capture|
          label = query.names[capture.index]
          node  = Node.new(capture.node, root.tree)
          case label
          when CONTENT  then content = node
          when LANGUAGE then name ||= node.text(buffer)
          end
        end

        next unless content && name
        next unless (nested = TreeSitter.language?(name.strip.downcase))
        next if nested.name == language.name

        region = Region.new(content.start_byte, content.end_byte,
          content.start_point.line, content.end_point.line)
        next if region.end_byte <= region.start_byte

        found << new(nested, region)
      end

      found
    end
  end
end
