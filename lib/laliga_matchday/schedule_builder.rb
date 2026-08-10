# frozen_string_literal: true

module ::LaligaMatchday
  # Turns football-data.org's raw season payload into the compact shape the
  # schedule view consumes.
  #
  # Deliberately ships kickoffs as raw UTC ISO8601 and lets the browser
  # localise them — that way every visitor sees their own timezone without
  # any server-side configuration, which matters for a US-based audience
  # following a Spanish league.
  class ScheduleBuilder
    CONFIRMED_STATUSES = %w[TIMED IN_PLAY PAUSED FINISHED AWARDED SUSPENDED].freeze
    PLAYED_STATUSES = %w[FINISHED AWARDED].freeze
    RESOLVED_STATUSES = %w[FINISHED AWARDED POSTPONED CANCELLED SUSPENDED].freeze

    def initialize(team_id:, season:, competition:)
      @team_id = team_id.to_s
      @season = season.to_s
      @competition = competition
    end

    def build(matches)
      grouped =
        matches
          .group_by { |m| m["matchday"] }
          .reject { |matchday, _| matchday.blank? }
          .sort_by { |matchday, _| matchday.to_i }

      {
        season: @season,
        season_label: season_label,
        competition: @competition,
        team_id: @team_id,
        fetched_at: Time.zone.now.iso8601,
        match_count: matches.size,
        matchdays: grouped.map { |matchday, round| serialize_round(matchday.to_i, round) },
      }
    end

    private

    def season_label
      start_year = @season.to_i
      "#{start_year}/#{(start_year + 1).to_s[-2..]}"
    end

    def serialize_round(matchday, round)
      serialized = round.map { |m| serialize_match(m) }.sort_by { |m| m[:utc_date] || "" }
      kickoffs = serialized.filter_map { |m| m[:utc_date] }.sort

      {
        matchday: matchday,
        state: round_state(serialized),
        first_kickoff: kickoffs.first,
        last_kickoff: kickoffs.last,
        has_club_match: serialized.any? { |m| m[:involves_club] },
        matches: serialized,
      }
    end

    # final    — every match resolved
    # live     — at least one match in progress
    # confirmed— all kickoffs locked in by La Liga
    # tbc      — none confirmed yet
    # mixed    — partially confirmed
    def round_state(matches)
      return "final" if matches.all? { |m| RESOLVED_STATUSES.include?(m[:status]) }
      return "live" if matches.any? { |m| %w[IN_PLAY PAUSED].include?(m[:status]) }

      confirmed = matches.count { |m| m[:confirmed] }
      return "confirmed" if confirmed == matches.size
      return "tbc" if confirmed.zero?

      "mixed"
    end

    def serialize_match(match)
      home = match["homeTeam"] || {}
      away = match["awayTeam"] || {}
      status = match["status"]

      {
        id: match["id"],
        utc_date: match["utcDate"],
        status: status,
        confirmed: CONFIRMED_STATUSES.include?(status),
        played: PLAYED_STATUSES.include?(status),
        involves_club: [home["id"].to_s, away["id"].to_s].include?(@team_id),
        home: serialize_team(home),
        away: serialize_team(away),
        score: {
          home: match.dig("score", "fullTime", "home"),
          away: match.dig("score", "fullTime", "away"),
        },
      }
    end

    def serialize_team(team)
      {
        id: team["id"],
        name: team["shortName"].presence || team["name"].presence || "TBD",
        crest: team["crest"],
        is_club: team["id"].to_s == @team_id,
      }
    end
  end
end
