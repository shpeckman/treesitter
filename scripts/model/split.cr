# scripts/model/split.cr

require "./collect"

module ModelBuild
  # Training, calibration and test sets, split by sample group so no corpus case, example file or source repository
  # lands on two sides, each capped per language so memory and evaluation time stay bounded.
  record Sets,
    train : Hash(String, Array(String)),
    calibration : Hash(String, Array(String)),
    test : Array(Sample),
    excluded : Hash(String, String)

  module Split
    SHARES    = {train: 0.7, calibration: 0.1}
    GROUP_CAP = 150
    CAL_CAP   = 150
    TEST_CAP  = 300
    MIN_TRAIN = 30
    MIN_TEST  = 5
    SETTINGS  = {SHARES, GROUP_CAP, CAL_CAP, TEST_CAP, MIN_TRAIN, MIN_TEST}

    def self.run(samples : Array(Sample), cap : Int32, rng : Random) : Sets
      train       = {} of String => Array(String)
      calibration = {} of String => Array(String)
      test        = [] of Sample
      excluded    = {} of String => String
      samples.group_by(&.language).each do |language, items|
        groups = items.group_by(&.group).values.map { |group| group.shuffle(rng).first(GROUP_CAP) }.shuffle!(rng)
        parts  = {[] of Sample, [] of Sample, [] of Sample}
        groups.each_with_index do |group, index|
          share = index / groups.size
          slot  = share < SHARES[:train] ? 0 : (share < SHARES[:train] + SHARES[:calibration] ? 1 : 2)
          parts[slot].concat(group)
        end
        if parts[0].size < MIN_TRAIN || parts[2].size < MIN_TEST
          excluded[language] = "#{parts[0].size} training and #{parts[2].size} test samples (need #{MIN_TRAIN} and #{MIN_TEST})"
          next
        end
        train[language]       = parts[0].shuffle(rng).first(cap).map(&.text)
        calibration[language] = parts[1].shuffle(rng).first(CAL_CAP).map(&.text)
        test.concat(parts[2].shuffle(rng).first(TEST_CAP))
      end
      Sets.new(train, calibration, test, excluded)
    end
  end
end
