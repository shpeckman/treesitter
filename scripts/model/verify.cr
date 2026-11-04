# scripts/model/verify.cr

require "json"

module ModelBuild
  # Verifies candidates in a worker process (`build/model verify`), because a grammar can hang inside its external
  # scanner where no cancellation reaches it (Perl did) or blow up its error recovery (Julia did). The worker parses
  # each request within `PARSE_TIMEOUT`; the build waits at most `DEADLINE` per request, and on a hang or crash kills
  # the worker, starts a new one and reports the candidate as hung.
  class Verifier
    PARSE_TIMEOUT = 100.milliseconds
    DEADLINE      = 2.seconds
    REPLY         = {timeout: "timeout", missing: "missing"}

    # What the worker found for one candidate: the share of the text its grammar could not fit, or why there is none.
    record Verdict, ratio : Float64?, hung : Bool, missing : Bool

    @process : Process?

    def initialize(@executable : String)
    end

    def check(language : String, text : String) : Verdict
      process = @process ||= spawn
      process.input.puts({language: language, text: text}.to_json)
      process.input.flush
      reply = process.output.gets
      raise IO::Error.new("worker exited") unless reply
      case reply
      when REPLY[:timeout] then Verdict.new(nil, true, false)
      when REPLY[:missing] then Verdict.new(nil, false, true)
      else                      reply.to_f?.try { |ratio| Verdict.new(ratio, false, false) } || raise IO::Error.new("unreadable reply #{reply.inspect}")
      end
    rescue IO::TimeoutError | IO::Error
      restart
      Verdict.new(nil, true, false)
    end

    def close : Nil
      @process.try do |process|
        process.input.close
        process.wait
      end
      @process = nil
    end

    # The worker side: answers one JSON request per line on *input* with a ratio, `timeout` or `missing`.
    def self.serve(input : IO, output : IO) : Nil
      parsers = {} of String => TreeSitter::Parser?
      input.each_line do |line|
        request  = JSON.parse(line)
        language = request["language"].as_s
        text     = request["text"].as_s
        parser   = parsers.fetch(language) do
          parsers[language] = TreeSitter::Language.find(language).try { |path| TreeSitter::Parser.new(TreeSitter::Language.load(path, language)) }
        end
        output.puts(if parser
          (tree = parser.parse(text, timeout: PARSE_TIMEOUT)) ? TreeSitter::Detector.error_ratio(tree.root, text) : REPLY[:timeout]
        else
          REPLY[:missing]
        end)
        output.flush
      end
    end

    private def spawn : Process
      process = Process.new(@executable, ["verify"], input: :pipe, output: :pipe, error: :inherit)
      process.output.as(IO::FileDescriptor).read_timeout = DEADLINE
      process
    end

    private def restart : Nil
      @process.try do |process|
        process.signal(Signal::KILL) rescue nil
        process.wait
      end
      @process = nil
    end
  end
end
