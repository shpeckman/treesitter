# scripts/model/sources.cr

require "json"
require "yaml"
require "./manifest"

module ModelBuild
  # A repository of real code from `scripts/sources.yml`, pinned to a commit, found by `discover` for one GitHub
  # language.
  struct Source
    include YAML::Serializable

    getter repo     : String
    getter revision : String
    getter license  : String
    getter language : String
    getter stars    : Int32

    def initialize(@repo : String, @revision : String, @license : String, @language : String, @stars : Int32)
    end
  end

  # Finds permissively licensed repositories per GitHub language through the search API, deterministically: most
  # stars first, no forks, archived repositories or templates, at most `MAX_SIZE_KB`.
  module Sources
    PERMISSIVE  = {"MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib", "Unlicense", "CC0-1.0", "0BSD"}
    MIN_STARS   = 50
    MAX_SIZE_KB = 100_000
    SKIP        = /awesome|cheat-?sheet|interview|roadmap|leetcode/i
    PAUSE       = 2.5.seconds
    HEADER      = <<-YAML
      # scripts/sources.yml
      #
      # Repositories of real code for the detector model, written by `crystal run --release scripts/model.cr -- discover`.
      # Review before building: remove repositories that are not representative. repo: GitHub owner/name;
      # revision: pinned commit; license: SPDX id (permissive only); language: the GitHub language it was found for.

      YAML

    def self.load(path : String) : Array(Source)
      File.exists?(path) ? Array(Source).from_yaml(File.read(path)) : [] of Source
    end

    def self.write(path : String, sources : Array(Source)) : Nil
      File.write(path, HEADER + sources.to_yaml.lchop("---\n"))
    end

    def self.discover(grammars : Array(Grammar), per_language : Int32) : Array(Source)
      chosen = [] of Source
      grammars.compact_map(&.github).uniq.each_with_index do |language, index|
        sleep PAUSE if index > 0
        found = search(language).reject { |item| chosen.any?(&.repo.==(item[0])) }.first(per_language)
        STDERR.puts "discover #{language}: #{found.size} repositories"
        found.each do |(repo, license, stars, branch)|
          revision = head(repo, branch) || next
          chosen << Source.new(repo, revision, license, language, stars)
        end
      end
      chosen
    end

    private def self.search(language : String) : Array({String, String, Int32, String})
      query  = %(language:"#{language}" stars:>#{MIN_STARS} fork:false archived:false size:<#{MAX_SIZE_KB})
      output = IO::Memory.new
      status = Process.run("gh", ["api", "-X", "GET", "search/repositories", "-f", "q=#{query}", "-f", "sort=stars",
                                  "-f", "order=desc", "-f", "per_page=100"], output: output, error: STDERR)
      raise "repository search failed for #{language}" unless status.success?
      JSON.parse(output.to_s)["items"].as_a.compact_map do |item|
        license = item["license"]?.try(&.as_h?).try(&.["spdx_id"]?).try(&.as_s?) || next
        next unless PERMISSIVE.includes?(license)
        next if item["is_template"]?.try(&.as_bool?) || SKIP.matches?(item["full_name"].as_s)
        {item["full_name"].as_s, license, item["stargazers_count"].as_i, item["default_branch"].as_s}
      end
    end

    private def self.head(repo : String, branch : String) : String?
      output = IO::Memory.new
      status = Process.run("git", ["ls-remote", "https://github.com/#{repo}.git", "refs/heads/#{branch}"], output: output)
      status.success? ? output.to_s.split.first? : nil
    end
  end
end
