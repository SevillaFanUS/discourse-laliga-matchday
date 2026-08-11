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
    # Bump whenever the serialized shape changes. The controller compares
    # this against the cached payload and rebuilds on mismatch — otherwise
    # a cache written by an older version keeps being served until the
    # scheduled job next runs, which can be hours after a deploy.
    SCHEMA_VERSION = 3

    CONFIRMED_STATUSES = %w[TIMED IN_PLAY PAUSED FINISHED AWARDED SUSPENDED].freeze
    PLAYED_STATUSES = %w[FINISHED AWARDED].freeze
    RESOLVED_STATUSES = %w[FINISHED AWARDED POSTPONED CANCELLED SUSPENDED].freeze

    def initialize(team_id:, season:, competition:)
      @team_id = team_id.to_s
      @season = season.to_s
      @competition = competition
    end

    def build(matches)
      @topic_ids = topic_id_lookup(matches)

      grouped =
        matches
          .group_by { |m| m["matchday"] }
          .reject { |matchday, _| matchday.blank? }
          .sort_by { |matchday, _| matchday.to_i }

      {
        schema_version: SCHEMA_VERSION,
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

    # The fixtures plugin (discourse-sevilla-fixtures) already creates
    # match threads and records the topic id against the same
    # football-data.org match id we're working with, so the two can be
    # joined here to link the schedule through to discussion.
    #
    # Looked up in one query rather than per match, and guarded so this
    # plugin still works standalone if the fixtures plugin isn't
    # installed.
    def topic_id_lookup(matches)
      return {} unless defined?(::SevillaFixture)

      external_ids = matches.filter_map { |m| m["id"] }
      return {} if external_ids.empty?

      ::SevillaFixture
        .where(external_id: external_ids)
        .where.not(discourse_topic_id: nil)
        .pluck(:external_id, :discourse_topic_id)
        .to_h
    rescue => e
      Rails.logger.warn("[#{::LaligaMatchday::PLUGIN_NAME}] topic id lookup failed: #{e.message}")
      {}
    end

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

    # final       — every match resolved
    # live        — at least one match in progress
    # confirmed   — every kickoff locked in
    # provisional — times published but not yet locked in
    # tbc         — no times at all yet
    #
    # Note: football-data.org reports SCHEDULED for La Liga fixtures that
    # already carry a real, specific kickoff time — it only flips to TIMED
    # close to the match. So SCHEDULED means "provisional", NOT "unknown";
    # treating it as unknown hides times we actually have.
    def round_state(matches)
      return "final" if matches.all? { |m| RESOLVED_STATUSES.include?(m[:status]) }
      return "live" if matches.any? { |m| %w[IN_PLAY PAUSED].include?(m[:status]) }
      return "tbc" if matches.none? { |m| m[:has_time] }
      return "confirmed" if matches.all? { |m| m[:confirmed] }

      "provisional"
    end

    def serialize_match(match)
      home = match["homeTeam"] || {}
      away = match["awayTeam"] || {}
      status = match["status"]

      has_time = match["utcDate"].present?

      {
        id: match["id"],
        utc_date: match["utcDate"],
        status: status,
        has_time: has_time,
        confirmed: CONFIRMED_STATUSES.include?(status),
        # A real time exists but La Liga may still move it.
        provisional: has_time && !CONFIRMED_STATUSES.include?(status),
        played: PLAYED_STATUSES.include?(status),
        topic_id: @topic_ids && @topic_ids[match["id"]],
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
