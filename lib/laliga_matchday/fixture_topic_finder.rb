# frozen_string_literal: true

module ::LaligaMatchday
  # Finds the match thread that discourse-sevilla-fixtures already made
  # for a given match.
  #
  # That plugin stores discourse_topic_id directly on each fixture, so
  # the right thread is a lookup rather than a guess — no title patterns
  # and no date windows. The only work here is joining two providers:
  # SevillaFixture is keyed on football-data ids while the live feed uses
  # ESPN event ids, so they are matched on kickoff day and team names.
  # Sevilla play at most once a day, which makes the day a reliable key
  # and the names a sanity check rather than the identifier.
  module FixtureTopicFinder
    DATE_COLUMNS = %w[utc_date kickoff_at starts_at kickoff date].freeze

    # Words that appear in so many Spanish club names that matching on
    # them would pair Real Madrid with Real Sociedad.
    STOPWORDS = %w[cf fc cd ud sad club de real deportivo futbol fútbol balompie balompié].freeze

    def self.available?
      defined?(::SevillaFixture) && ::SevillaFixture.respond_to?(:column_names)
    rescue StandardError
      false
    end

    def self.date_column
      return @date_column if defined?(@date_column)

      @date_column = DATE_COLUMNS.find { |c| ::SevillaFixture.column_names.include?(c) }
    rescue StandardError
      @date_column = nil
    end

    # @return [Integer, nil] the topic id of the match thread
    def self.topic_id_for(kickoff:, home:, away:)
      return nil unless available?
      return nil if kickoff.nil?

      column = date_column
      return nil if column.nil?

      records =
        ::SevillaFixture
          .where.not(discourse_topic_id: nil)
          .where("#{column} >= ? AND #{column} <= ?", kickoff - 18.hours, kickoff + 18.hours)
          .to_a

      candidates =
        records.map do |record|
          {
            topic_id: record.discourse_topic_id,
            at: record.public_send(column),
            home: record.home_team.to_s,
            away: record.away_team.to_s,
          }
        end

      chosen = pick(candidates, kickoff: kickoff, home: home, away: away)
      return nil if chosen.nil?
      return nil unless ::Topic.exists?(id: chosen[:topic_id], deleted_at: nil)

      chosen[:topic_id]
    rescue StandardError => e
      Rails.logger.warn(
        "[#{::LaligaMatchday::PLUGIN_NAME}] fixture topic lookup failed: #{e.class}: #{e.message}",
      )
      nil
    end

    # Pure. Picks the best candidate for a kickoff and a pair of team
    # names, or nil when nothing is close enough.
    def self.pick(candidates, kickoff:, home:, away:)
      return nil if candidates.nil? || candidates.empty?

      scored =
        candidates.map do |candidate|
          [candidate, score(candidate, kickoff: kickoff, home: home, away: away)]
        end

      best, points = scored.max_by { |(_candidate, value)| value }

      # A candidate on the right day with no recognisable team in common
      # is more likely to be a different match than a naming quirk.
      return nil if points <= 0

      best
    end

    def self.score(candidate, kickoff:, home:, away:)
      hours = ((candidate[:at].to_time - kickoff.to_time) / 3600.0).abs rescue 999

      # Same calendar day is the strong signal; closer is better.
      points = hours <= 18 ? (18 - hours) / 18.0 : -1
      return -1 if points.negative?

      names = tokens(candidate[:home]) + tokens(candidate[:away])
      wanted = tokens(home) + tokens(away)
      overlap = (names & wanted).size

      return -1 if overlap.zero?

      points + overlap
    end

    def self.tokens(name)
      name
        .to_s
        .downcase
        .gsub(/[^a-z0-9áéíóúñü ]/, " ")
        .split
        .map { |word| fold(word) }
        .reject { |word| word.length < 3 || STOPWORDS.include?(word) }
        .uniq
    end

    def self.fold(word)
      word.tr("áéíóúñü", "aeiounu")
    end
  end
end
