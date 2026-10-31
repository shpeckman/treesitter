# src/tree_sitter/predicate.cr

module TreeSitter
  # A text test on a query pattern, checked against the captured nodes' text before a match is reported: `#eq?`,
  # `#match?`, `#any-of?`, their `not-` forms and the `vim-` and `lua-` spellings of `#match?`. Directives (`#set!`)
  # and unknown predicates are skipped, so the pattern matches as if they were absent.
  struct Predicate
    # What a predicate compares.
    enum Test
      # The capture's text equals a string or another capture's text.
      Eq
      # The capture's text matches a regular expression.
      Match
      # The capture's text is one of several strings.
      AnyOf
    end

    # Predicate name → `{test, negated, Lua pattern}`.
    TESTS = {
      "eq?"            => {Test::Eq, false, false},
      "not-eq?"        => {Test::Eq, true, false},
      "match?"         => {Test::Match, false, false},
      "not-match?"     => {Test::Match, true, false},
      "vim-match?"     => {Test::Match, false, false},
      "not-vim-match?" => {Test::Match, true, false},
      "lua-match?"     => {Test::Match, false, true},
      "not-lua-match?" => {Test::Match, true, true},
      "any-of?"        => {Test::AnyOf, false, false},
      "not-any-of?"    => {Test::AnyOf, true, false},
    }

    # Lua character class letter → the regular expression range it stands for (uppercase negates).
    LUA_CLASSES = {
      'a' => "A-Za-z",
      'c' => "\\x00-\\x1f\\x7f",
      'd' => "0-9",
      'g' => "!-~",
      'l' => "a-z",
      'p' => "!-/:-@\\[-`{-~",
      's' => "\\s",
      'u' => "A-Z",
      'w' => "A-Za-z0-9",
      'x' => "0-9A-Fa-f",
    }

    # The comparison.
    getter test : Test
    # Whether the result is inverted.
    getter? negated : Bool
    # Capture id whose text is tested.
    getter capture : Int32
    # Capture id compared against, for `#eq?` between two captures.
    getter other : Int32?
    # String operands.
    getter values : Array(String)
    # Compiled pattern of a `Match` test.
    getter regex : Regex?

    def initialize(@test : Test, @negated : Bool, @capture : Int32, @other : Int32?, @values : Array(String), @regex : Regex?)
    end

    # The predicates of *pattern* in the query at *query*, in source order.
    def self.list(query : Void*, pattern : Int32) : Array(Predicate)
      count = 0_u32
      steps = LibTreeSitter.ts_query_predicates_for_pattern(query, pattern.to_u32, pointerof(count))
      found = [] of Predicate
      group = [] of LibTreeSitter::QueryPredicateStep
      count.times do |index|
        step = steps[index]
        if step.step_type.done?
          build(query, group).try { |predicate| found << predicate }
          group.clear
        else
          group << step
        end
      end
      found
    end

    # A regular expression for the Lua pattern *pattern*: `%` classes become ranges and `-` outside a set becomes a
    # lazy `*?`.
    def self.lua(pattern : String) : String
      String.build do |io|
        inside = false
        reader = Char::Reader.new(pattern)
        while reader.has_next?
          char = reader.current_char
          if char == '%' && reader.has_next? && (letter = reader.next_char) != Char::ZERO
            if range = LUA_CLASSES[letter.downcase]?
              if inside
                io << range
              else
                io << (letter.uppercase? ? "[^" : "[") << range << ']'
              end
            else
              io << Regex.escape(letter.to_s)
            end
          else
            case char
            when '[' then inside = true
            when ']' then inside = false
            end
            io << (char == '-' && !inside ? "*?" : char.to_s)
          end
          reader.next_char
        end
      end
    end

    # Whether the match whose *captures* came from *tree* passes this test, reading text from *source*. A capture
    # absent from the match passes.
    def satisfied?(captures : Slice(LibTreeSitter::QueryCapture), tree : Tree, source : Source) : Bool
      text = text_of(@capture, captures, tree, source) || return true
      result = case @test
               in .eq?
                 expected = (other = @other) ? text_of(other, captures, tree, source) : @values.first?
                 return true unless expected
                 text == expected
               in .match?
                 @regex.try(&.matches?(text)) || false
               in .any_of?
                 @values.includes?(text)
               end
      @negated ? !result : result
    end

    private def text_of(capture : Int32, captures : Slice(LibTreeSitter::QueryCapture), tree : Tree, source : Source) : String?
      captures.each do |entry|
        next unless entry.index == capture
        node = Node.new(entry.node, tree)
        return source.text(node.start_byte, node.end_byte)
      end
      nil
    end

    private def self.build(query : Void*, group : Array(LibTreeSitter::QueryPredicateStep)) : Predicate?
      head = group.first? || return nil
      return nil unless head.step_type.string?
      test, negated, lua = TESTS[string(query, head.value_id)]? || return nil
      target = group[1]? || return nil
      return nil unless target.step_type.capture?
      rest = group[2..]? || [] of LibTreeSitter::QueryPredicateStep
      other = rest.first?.try { |step| step.step_type.capture? ? step.value_id.to_i : nil }
      values = rest.select(&.step_type.string?).map { |step| string(query, step.value_id) }
      regex = nil
      if test.match?
        source = values.first? || return nil
        regex = Regex.new(lua ? lua(source) : source) rescue return nil
      end
      new(test, negated, target.value_id.to_i, other, values, regex)
    end

    private def self.string(query : Void*, id : UInt32) : String
      length = 0_u32
      pointer = LibTreeSitter.ts_query_string_value_for_id(query, id, pointerof(length))
      String.new(pointer, length)
    end
  end
end
