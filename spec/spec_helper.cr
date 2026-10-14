# spec/spec_helper.cr
require "spec"
require "../src/treesitter"

struct Plain
  include Scribe::Graphemes

  WIDE = [0x1100..0x115F, 0x2E80..0xA4CF, 0xAC00..0xD7A3, 0xF900..0xFAFF, 0xFF00..0xFF60, 0x1F300..0x1FAFF]

  def boundaries(text : String) : Array(Int32)
    marks = [0]
    text.each_grapheme { |grapheme| marks << marks.last + grapheme.to_s.bytesize }
    marks
  end

  def kind(cluster : Bytes) : Scribe::ClusterKind
    char = String.new(cluster)[0]? || return Scribe::ClusterKind::Other
    return Scribe::ClusterKind::Space if char.whitespace?
    return Scribe::ClusterKind::Word if char.alphanumeric? || char == '_'
    return Scribe::ClusterKind::Other if char.control?

    Scribe::ClusterKind::Punct
  end

  def width(cluster : Bytes) : Int32
    code = String.new(cluster)[0]?.try(&.ord) || return 0
    WIDE.any?(&.includes?(code)) ? 2 : 1
  end
end

def document(text : String) : Scribe::Document
  Scribe::Document.new(Plain.new, text, filter: Scribe::MultiLine.new)
end

def kinds(source : Scribe::TokenSource, buffer : Scribe::Buffer, line : Int32) : Array({String, String})
  row = buffer.line(line)
  source.tokens(buffer, line).map { |token| {row.slice(token.start, token.stop), token.kind} }
end

def fresh_tokens(subject : Scribe::Document, language : TreeSitter::Language) : Array(Array(Scribe::Highlighter::Token))
  copy   = document(subject.value)
  syntax = TreeSitter::Syntax.new(copy, language)
  Array.new(copy.buffer.line_count) { |line| syntax.tokens(copy.buffer, line) }
end
