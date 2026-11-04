# scripts/model/cache.cr

require "digest/sha256"
require "json"
require "./collect"

module ModelBuild
  # The verified samples and tallies of a collection, as JSON Lines (a header with the stamp and tallies, then one
  # sample per line), reused while the stamp of everything that shaped them is unchanged.
  module Cache
    def self.stamp(*parts) : String
      Digest::SHA256.hexdigest(parts.map(&.to_s).join('\n'))
    end

    def self.load(path : String, stamp : String) : {Array(Sample), Hash(String, Tally)}?
      return nil unless File.exists?(path)
      File.open(path) do |file|
        header = JSON.parse(file.gets || return nil)
        return nil unless header["stamp"]?.try(&.as_s?) == stamp
        tallies = Hash(String, Tally).from_json(header["tallies"].to_json)
        samples = [] of Sample
        file.each_line { |line| samples << Sample.from_json(line) }
        {samples, tallies}
      end
    rescue JSON::ParseException | IO::EOFError
      nil
    end

    def self.write(path : String, stamp : String, samples : Array(Sample), tallies : Hash(String, Tally)) : Nil
      temporary = "#{path}.#{Process.pid}.tmp"
      File.open(temporary, "w") do |file|
        JSON.build(file) do |json|
          json.object do
            json.field "stamp", stamp
            json.field "tallies", tallies
          end
        end
        file.puts
        samples.each { |sample| sample.to_json(file); file.puts }
        file.fsync
      end
      File.rename(temporary, path)
    ensure
      File.delete?(temporary) if temporary
    end
  end
end
