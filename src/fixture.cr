# src/fixture.cr

require "./treesitter"

module TreeSitter
  # Grammars bundled for specs (`require "treesitter/fixture"`), compiled with `cc` into shared libraries in a temporary
  # directory on first use. Not loaded by `require "treesitter"`.
  module Fixture
    # Where the compiled libraries go; removed by `clean`.
    DIRECTORY = File.join(Dir.tempdir, "treesitter-fixture-#{Process.pid}")
    # Sources of the bundled grammars.
    SOURCES = File.expand_path("../fixtures", __DIR__)

    # The shared library of the bundled grammar *name* (`"json"`), compiled on first use; raises `Error` when `cc` fails.
    def self.library(name : String) : String
      path = File.join(DIRECTORY, "#{name}.so")
      return path if File.exists?(path)
      grammar = File.join(SOURCES, name)
      Dir.mkdir_p(DIRECTORY)
      compiler = ENV["CC"]? || "cc"
      arguments = ["-shared", "-fPIC", "-O1", "-I#{grammar}", File.join(grammar, "parser.c"), "-o", path]
      error = IO::Memory.new
      status = Process.run(compiler, arguments, error: error)
      raise Error.new("#{compiler} failed for #{name}: #{error}") unless status.success?
      path
    end

    # The bundled grammar *name*, loaded.
    def self.language(name : String) : Language
      Language.load(library(name), name)
    end

    # Removes the compiled libraries.
    def self.clean : Nil
      Dir.glob(File.join(DIRECTORY, "*.so")).each { |path| File.delete(path) }
      Dir.delete(DIRECTORY) if Dir.exists?(DIRECTORY)
    end
  end
end
