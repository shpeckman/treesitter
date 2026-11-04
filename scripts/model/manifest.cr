# scripts/model/manifest.cr

require "yaml"

module ModelBuild
  # One row of `scripts/languages.yml`: a grammar, the pinned repository it comes from, where its samples live and
  # which files of other repositories it labels.
  struct Grammar
    include YAML::Serializable

    getter name       : String
    getter repo       : String
    getter revision   : String
    getter license    : String
    getter github     : String?
    getter corpus     : Array(String) = ["test/corpus"]
    getter examples   : Array(String) = ["examples"]
    getter extensions : Array(String) = [] of String

    @family : String?

    def family : String
      @family || @name
    end

    def directories : Array(String)
      corpus + examples
    end
  end

  # File name or extension → grammar, built from the manifest's `extensions`; entries claimed by more than one
  # grammar (`h`) are dropped, so no file gets an ambiguous label.
  struct Extensions
    getter shared : Array(String)

    @table : Hash(String, String)

    def initialize(grammars : Array(Grammar))
      claims  = grammars.flat_map { |grammar| grammar.extensions.map { |entry| {entry, grammar.name} } }.group_by(&.[0])
      @shared = claims.select { |_, owners| owners.size > 1 }.keys.sort
      @table  = claims.reject { |entry, _| @shared.includes?(entry) }.transform_values(&.first[1])
    end

    def entries : Array(String)
      @table.keys.sort
    end

    def lookup(basename : String) : String?
      return @table[basename] if @table.has_key?(basename)
      basename.each_char_with_index do |char, index|
        next unless char == '.'
        if language = @table[basename[(index + 1)..]]?
          return language
        end
      end
      nil
    end
  end

  module Manifest
    def self.load(path : String) : Array(Grammar)
      grammars = Array(Grammar).from_yaml(File.read(path))
      duplicates = grammars.map(&.name).tally.select { |_, count| count > 1 }.keys
      raise ArgumentError.new("duplicate grammars in #{path}: #{duplicates.join(", ")}") unless duplicates.empty?
      grammars
    end
  end
end
