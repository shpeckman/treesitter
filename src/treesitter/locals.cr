# src/treesitter/locals.cr
module TreeSitter
  class Locals
    DEFINITION = "local.definition"
    REFERENCE  = "local.reference"
    SCOPE      = "local.scope"

    getter query : Query

    @definitions : Hash(String, Array({Int32, Int32}))
    @references  : Hash(Int32, String)
    @scopes      : Array({Int32, Int32})

    def initialize(@query : Query, root : Node, buffer : Scribe::Buffer)
      @definitions = {} of String => Array({Int32, Int32})
      @references  = {} of Int32 => String
      @scopes      = [] of {Int32, Int32}

      @query.each_capture(root, buffer) do |capture|
        case capture.name
        when DEFINITION
          name = capture.node.text(buffer)
          (@definitions[name] ||= [] of {Int32, Int32}) << {capture.node.start_byte, capture.node.end_byte}
        when REFERENCE
          @references[capture.node.start_byte] = capture.node.text(buffer)
        when SCOPE
          @scopes << {capture.node.start_byte, capture.node.end_byte}
        end
      end
      @scopes.sort_by! { |(from, to)| {from, -to} }
    end

    def empty? : Bool
      @definitions.empty? && @references.empty?
    end

    def definitions : Int32
      @definitions.sum { |_name, found| found.size }
    end

    def defined?(name : String) : Bool
      @definitions.has_key?(name)
    end

    def local?(byte : Int32) : Bool
      name = @references[byte]? || return false

      @definitions.has_key?(name)
    end

    def refine(kind : String, byte : Int32) : String
      return kind unless local?(byte)
      return kind if kind.starts_with?("variable")

      "variable"
    end
  end
end
