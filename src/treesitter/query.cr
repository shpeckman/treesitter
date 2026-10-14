# src/treesitter/query.cr
module TreeSitter
  class Error < Exception
  end

  class QueryError < Error
    getter offset : Int32
    getter kind   : LibTreeSitter::QueryError

    def initialize(@offset : Int32, @kind : LibTreeSitter::QueryError, source : String)
      before = source.byte_slice(0, @offset.clamp(0, source.bytesize))
      line   = before.count('\n') + 1
      column = before.size - (before.rindex('\n').try(&.+(1)) || 0) + 1
      super("#{@kind.to_s.downcase} error in query at line #{line}, column #{column}")
    end
  end

  record Capture, node : Node, name : String, index : Int32, pattern : Int32

  class Query
    enum Test
      Eq
      NotEq
      Match
      NotMatch
      AnyOf
      NotAnyOf
    end

    TESTS = {
      "eq?"         => Test::Eq,
      "not-eq?"     => Test::NotEq,
      "match?"      => Test::Match,
      "not-match?"  => Test::NotMatch,
      "any-of?"     => Test::AnyOf,
      "not-any-of?" => Test::NotAnyOf,
    }

    record Predicate, test : Test, capture : UInt32, other : UInt32?, values : Array(String), regex : Regex?

    alias Properties = Hash(String, String)

    getter language : Language
    getter names    : Array(String)

    @predicates : Array(Array(Predicate))

    def initialize(@language : Language, source : String)
      offset = 0_u32
      kind   = LibTreeSitter::QueryError::None
      @raw   = LibTreeSitter.ts_query_new(@language, source, source.bytesize.to_u32, pointerof(offset), pointerof(kind))
      raise QueryError.new(offset.to_i32, kind, source) if @raw.null?

      @cursor     = LibTreeSitter.ts_query_cursor_new
      @names      = Array(String).new(LibTreeSitter.ts_query_capture_count(@raw)) { |index| capture_name(index.to_u32) }
      @predicates = Array(Array(Predicate)).new(pattern_count) { |index| compile(index.to_u32) }
      @settings   = Array(Properties).new(pattern_count) { |index| settings(index.to_u32) }
    end

    def properties(pattern : Int32) : Properties
      @settings[pattern]? || Properties.new
    end

    def finalize
      LibTreeSitter.ts_query_cursor_delete(@cursor)
      LibTreeSitter.ts_query_delete(@raw)
    end

    def pattern_count : Int32
      LibTreeSitter.ts_query_pattern_count(@raw).to_i32
    end

    def each_match(node : Node, source : String | Scribe::Buffer, from : Int32 = 0, to : Int32 = Int32::MAX, & : Int32, Slice(LibTreeSitter::QueryCapture) ->) : Nil
      LibTreeSitter.ts_query_cursor_set_byte_range(@cursor, from.to_u32, to.to_u32)
      LibTreeSitter.ts_query_cursor_exec(@cursor, @raw, node)
      match = LibTreeSitter::QueryMatch.new
      while LibTreeSitter.ts_query_cursor_next_match(@cursor, pointerof(match))
        captures = Slice.new(match.captures, match.capture_count.to_i32)
        next unless passes?(@predicates[match.pattern_index], captures, node.tree, source)

        yield match.pattern_index.to_i32, captures
      end
    end

    def each_capture(node : Node, source : String | Scribe::Buffer, from : Int32 = 0, to : Int32 = Int32::MAX, & : Capture ->) : Nil
      tree = node.tree
      each_match(node, source, from, to) do |pattern, captures|
        captures.each do |capture|
          yield Capture.new(Node.new(capture.node, tree), @names[capture.index], capture.index.to_i32, pattern)
        end
      end
    end

    def captures(node : Node, source : String | Scribe::Buffer, from : Int32 = 0, to : Int32 = Int32::MAX) : Array(Capture)
      found = [] of Capture
      each_capture(node, source, from, to) { |capture| found << capture }
      found
    end

    private def passes?(predicates : Array(Predicate), captures : Slice(LibTreeSitter::QueryCapture), tree : Tree, source : String | Scribe::Buffer) : Bool
      predicates.all? do |predicate|
        captures.all? do |capture|
          next true unless capture.index == predicate.capture

          check(predicate, Node.new(capture.node, tree).text(source), captures, tree, source)
        end
      end
    end

    private def check(predicate : Predicate, text : String, captures : Slice(LibTreeSitter::QueryCapture), tree : Tree, source : String | Scribe::Buffer) : Bool
      case predicate.test
      in .eq?, .not_eq?
        expected = if other = predicate.other
                     captures.find(&.index.==(other)).try { |found| Node.new(found.node, tree).text(source) }
                   else
                     predicate.values.first?
                   end
        return true if expected.nil?

        (text == expected) == predicate.test.eq?
      in .match?, .not_match?
        predicate.regex.not_nil!.matches?(text) == predicate.test.match?
      in .any_of?, .not_any_of?
        predicate.values.includes?(text) == predicate.test.any_of?
      end
    end

    private def compile(pattern : UInt32) : Array(Predicate)
      count = 0_u32
      steps = LibTreeSitter.ts_query_predicates_for_pattern(@raw, pattern, pointerof(count))
      found = [] of Predicate
      group = [] of LibTreeSitter::QueryPredicateStep
      count.times do |index|
        step = steps[index]
        if step.type.done?
          predicate(group).try { |built| found << built }
          group.clear
        else
          group << step
        end
      end
      found
    end

    private def settings(pattern : UInt32) : Properties
      count = 0_u32
      steps = LibTreeSitter.ts_query_predicates_for_pattern(@raw, pattern, pointerof(count))
      found = Properties.new
      group = [] of LibTreeSitter::QueryPredicateStep
      count.times do |index|
        step = steps[index]
        if step.type.done?
          setting(group, found)
          group.clear
        else
          group << step
        end
      end
      found
    end

    private def setting(steps : Array(LibTreeSitter::QueryPredicateStep), into : Properties) : Nil
      head = steps.first? || return
      return unless head.type.string? && string_value(head.value_id) == "set!"

      words = steps[1..].select(&.type.string?).map { |step| string_value(step.value_id) }
      return if words.size < 2

      into[words[0]] = words[1]
    end

    private def predicate(steps : Array(LibTreeSitter::QueryPredicateStep)) : Predicate?
      head = steps.first? || return nil
      return nil unless head.type.string?

      test    = TESTS[string_value(head.value_id)]? || return nil
      subject = steps[1]?
      return nil unless subject && subject.type.capture?

      rest   = steps[2..]
      other  = rest.first?.try { |step| step.type.capture? ? step.value_id : nil }
      values = rest.select(&.type.string?).map { |step| string_value(step.value_id) }
      regex  = test.match? || test.not_match? ? Regex.new(values.first? || "") : nil
      Predicate.new(test, subject.value_id, other, values, regex)
    end

    private def capture_name(index : UInt32) : String
      length = 0_u32
      String.new(LibTreeSitter.ts_query_capture_name_for_id(@raw, index, pointerof(length)), length)
    end

    private def string_value(index : UInt32) : String
      length = 0_u32
      String.new(LibTreeSitter.ts_query_string_value_for_id(@raw, index, pointerof(length)), length)
    end
  end
end
