# scripts/model/fetch.cr

require "file_utils"
require "./manifest"
require "./sources"

module ModelBuild
  # Sparse, shallow checkouts of pinned repositories: the grammars' corpus and example directories, and the real-code
  # sources' files with known extensions (vendored directories left out), several at a time.
  module Fetch
    MARKER   = ".model-fetch"
    WORKERS  = 6
    VENDORED = {"node_modules", "vendor", "third_party", "third-party", "dist", "build", "target", "out", "deps", "external", ".git"}

    def self.directory(root : String, repo : String) : String
      File.join(root, repo.tr("/", "_"))
    end

    def self.grammars(grammars : Array(Grammar), root : String) : Array(String)
      jobs = grammars.group_by { |grammar| {grammar.repo, grammar.revision} }.map do |(repo, revision), rows|
        {repo, revision, rows.flat_map(&.directories).uniq!.sort!.map { |path| "/#{path}/" }}
      end
      run(jobs, root)
    end

    def self.sources(sources : Array(Source), extensions : Extensions, root : String) : Array(String)
      patterns = extensions.entries.flat_map { |entry| [entry, "*.#{entry}"] } + VENDORED.to_a.map { |name| "!#{name}/" }
      run(sources.map { |source| {source.repo, source.revision, patterns} }, root)
    end

    private def self.run(jobs : Array({String, String, Array(String)}), root : String) : Array(String)
      queue    = Channel({String, String, Array(String)}).new
      finished = Channel(String?).new
      WORKERS.times do
        spawn do
          while job = queue.receive?
            repo, revision, patterns = job
            finished.send(begin
              checkout(directory(root, repo), repo, revision, patterns)
              nil
            rescue ex
              "#{repo}: #{ex.message}"
            end)
          end
        end
      end
      spawn do
        jobs.each { |job| queue.send(job) }
        queue.close
      end
      failures = Array.new(jobs.size) { finished.receive }.compact
      failures.each { |failure| STDERR.puts "fetch failed: #{failure}" }
      failures
    end

    private def self.checkout(target : String, repo : String, revision : String, patterns : Array(String)) : Nil
      stamp  = ([revision] + patterns).join('\n')
      marker = File.join(target, MARKER)
      return if File.exists?(marker) && File.read(marker) == stamp

      STDERR.puts "fetch #{repo} @ #{revision[0, 12]}"
      FileUtils.rm_rf(target)
      Dir.mkdir_p(target)
      git(target, ["init", "-q"])
      git(target, ["remote", "add", "origin", "https://github.com/#{repo}.git"])
      git(target, ["sparse-checkout", "set", "--no-cone"] + patterns)
      git(target, ["fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", revision])
      git(target, ["checkout", "-q", "FETCH_HEAD"])
      File.write(marker, stamp)
    end

    private def self.git(directory : String, arguments : Array(String)) : Nil
      error  = IO::Memory.new
      status = Process.run("git", ["-C", directory] + arguments, error: error)
      raise "git #{arguments.first} failed: #{error.to_s.strip}" unless status.success?
    end
  end
end
