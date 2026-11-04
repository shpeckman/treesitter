# scripts/model/corpus_file.cr

module ModelBuild
  # Reads a tree-sitter test corpus file the way `tree-sitter test` does (cli/src/test.rs, v0.25.2): the first
  # header's suffix applies to every header and divider in the file, and a case's input ends at the longest
  # matching line of dashes (the last one on a tie).
  module CorpusFile
    HEADER  = /(?m)^(?<equals>={3,})(?<suffix1>[^=\r\n][^\r\n]*)?\r?\n(?<body>(?:(?:[^=\r\n]|\s+:)[^\r\n]*\r?\n)+)===+(?<suffix2>[^=\r\n][^\r\n]*)?\r?\n/
    DIVIDER = /(?m)^(?<hyphens>-{3,})(?<suffix>[^-\r\n][^\r\n]*)?\r?\n/

    # One test case: its input and the attributes that decide whether it is usable as a sample.
    record Case, name : String, input : String, languages : Array(String), error : Bool, skip : Bool

    def self.parse(content : String) : Array(Case)
      suffix  = HEADER.match(content).try(&.["suffix1"]?)
      headers = content.scan(HEADER).select { |header| header["suffix1"]? == suffix && header["suffix2"]? == suffix }
      cases   = [] of Case
      headers.each_with_index do |header, index|
        start   = header.byte_end(0)
        stop    = headers[index + 1]?.try(&.byte_begin(0)) || content.bytesize
        section = content.byte_slice(start, stop - start)
        divider = section.scan(DIVIDER).select { |line| line["suffix"]? == suffix }.max_by? { |line| {line[0].bytesize, line.byte_begin(0)} }
        next unless divider
        input = section.byte_slice(0, divider.byte_begin(0)).chomp
        cases << attributes(header["body"], input)
      end
      cases
    end

    private def self.attributes(body : String, input : String) : Case
      name      = [] of String
      languages = [] of String
      error     = false
      skip      = false
      marked    = false
      body.each_line do |line|
        marker = line.strip
        case marker.split('(').first
        when ":error"                  then marked, error = true, true
        when ":skip"                   then marked, skip = true, true
        when ":fail-fast", ":platform" then marked = true
        when ":language"
          marked = true
          languages << marker.lchop(":language(").rchop(")")
        else
          name << line unless marked
        end
      end
      Case.new(name.join('\n').strip, input, languages, error && !skip, skip)
    end
  end
end
