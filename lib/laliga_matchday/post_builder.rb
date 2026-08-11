# frozen_string_literal: true

module ::LaligaMatchday
  # Builds the title and markdown body for matchday preview / review
  # topics. Pure formatting — no API calls, no posting, so it's easy to
  # eyeball the output from the rails console before trusting it to a job.
  class PostBuilder
    PLAYED_STATUSES = %w[FINISHED AWARDED].freeze

    def initialize(team_id: nil, timezones: [], standings_rows: 10, competition_label: "La Liga")
      @team_id = team_id.to_s
      @timezones = timezones.presence || ["Europe/Madrid"]
      @standings_rows = standings_rows
      @competition_label = competition_label
    end

    # --- titles -----------------------------------------------------------

    def preview_title(matchday:, season_label:)
      "#{@competition_label} Matchday #{matchday} Preview — #{season_label}"
    end

    def review_title(matchday:, season_label:)
      "#{@competition_label} Matchday #{matchday} Results — #{season_label}"
    end

    # --- bodies -----------------------------------------------------------

    def preview_body(matchday:, matches:, standings:, season_label:)
      parts = []
      parts << "## #{@competition_label} Matchday #{matchday} — #{season_label}"
      parts << ""
      parts << fixtures_table(matches)

      if matches.any? { |m| m["status"] == "SCHEDULED" }
        parts << ""
        parts << "*Kickoff times marked **TBC** haven't been confirmed by La Liga yet — they're usually locked in about two weeks out, and this post reflects the schedule as of posting.*"
      end

      if standings.present?
        parts << ""
        parts << "### Table going in"
        parts << ""
        parts << standings_table(standings)
      end

      parts.join("\n")
    end

    # Rendered repeatedly as a round plays out — the same post is edited
    # in place rather than a new one being created per result, so the
    # body has to read sensibly whether 1 of 10 matches are in or all of
    # them.
    def review_body(matchday:, matches:, standings:, scorers:, season_label:, complete: false, updated_at: nil)
      played = matches.count { |m| PLAYED_STATUSES.include?(m["status"]) }

      parts = []
      parts << "## #{@competition_label} Matchday #{matchday} Results — #{season_label}"
      parts << ""
      parts << progress_line(played, matches.size, complete, updated_at)
      parts << ""
      parts << results_table(matches)

      if standings.present?
        parts << ""
        parts << "### Table after Matchday #{matchday}"
        parts << ""
        parts << standings_table(standings)
      end

      if scorers.present?
        parts << ""
        parts << "### Top scorers"
        parts << ""
        parts << scorers_table(scorers)
      end

      parts.join("\n")
    end

    def progress_line(played, total, complete, updated_at)
      stamp = updated_at ? " · updated #{updated_at.strftime("%-d %b, %-I:%M %p")}" : ""

      if complete
        "*Final — all #{total} matches played#{stamp}.*"
      else
        "*#{played} of #{total} matches played. This post updates as results come in#{stamp}.*"
      end
    end

    # --- tables -----------------------------------------------------------

    def fixtures_table(matches)
      rows =
        matches.map do |match|
          label = match_label(match)
          "| #{label} | #{kickoff_label(match)} |"
        end

      <<~TABLE.strip
        | Match | Kickoff |
        | --- | --- |
        #{rows.join("\n")}
      TABLE
    end

    def results_table(matches)
      rows =
        matches.map do |match|
          "| #{match_label(match)} | #{result_label(match)} |"
        end

      <<~TABLE.strip
        | Match | Result |
        | --- | --- |
        #{rows.join("\n")}
      TABLE
    end

    def standings_table(standings)
      rows = standings.first(@standings_rows)

      # Always include our own club even if it's outside the cut.
      unless rows.any? { |row| row.dig("team", "id").to_s == @team_id }
        own = standings.find { |row| row.dig("team", "id").to_s == @team_id }
        rows = rows + [own] if own
      end

      body =
        rows.map do |row|
          own = row.dig("team", "id").to_s == @team_id
          name = row.dig("team", "shortName") || row.dig("team", "name")
          name = "**#{name}**" if own

          "| #{row["position"]} | #{name} | #{row["playedGames"]} | #{row["won"]} | #{row["draw"]} | #{row["lost"]} | #{row["goalDifference"]} | #{row["points"]} |"
        end

      <<~TABLE.strip
        | # | Team | P | W | D | L | GD | Pts |
        | --- | --- | --- | --- | --- | --- | --- | --- |
        #{body.join("\n")}
      TABLE
    end

    def scorers_table(scorers)
      rows =
        scorers.map do |entry|
          player = entry.dig("player", "name")
          team = entry.dig("team", "shortName") || entry.dig("team", "name")
          team = "**#{team}**" if entry.dig("team", "id").to_s == @team_id
          goals = entry["goals"]

          "| #{player} | #{team} | #{goals} |"
        end

      <<~TABLE.strip
        | Player | Team | Goals |
        | --- | --- | --- |
        #{rows.join("\n")}
      TABLE
    end

    # --- helpers ----------------------------------------------------------

    def match_label(match)
      home = team_name(match["homeTeam"])
      away = team_name(match["awayTeam"])
      label = "#{home} vs #{away}"
      involves_club?(match) ? "**#{label}**" : label
    end

    def team_name(team)
      return "TBD" if team.blank?

      team["shortName"].presence || team["name"].presence || "TBD"
    end

    def involves_club?(match)
      return false if @team_id.blank?

      [match.dig("homeTeam", "id").to_s, match.dig("awayTeam", "id").to_s].include?(@team_id)
    end

    def kickoff_label(match)
      utc = parse_time(match["utcDate"])
      return "TBC" if utc.blank?

      label = format_across_timezones(utc)
      # SCHEDULED means the fixture exists but La Liga hasn't locked the
      # exact slot yet, so the date/time here is provisional.
      match["status"] == "SCHEDULED" ? "#{label} *(TBC)*" : label
    end

    def format_across_timezones(utc)
      primary, *rest = @timezones

      primary_time = utc.in_time_zone(primary)
      parts = ["#{primary_time.strftime("%a %-d %b, %-I:%M %p")} #{primary_time.zone}"]

      rest.each do |zone|
        local = utc.in_time_zone(zone)
        parts << "#{local.strftime("%-I:%M %p")} #{local.zone}"
      end

      parts.join(" / ")
    rescue ArgumentError, TypeError => e
      Rails.logger.warn("[#{::LaligaMatchday::PLUGIN_NAME}] timezone formatting failed: #{e.message}")
      utc.strftime("%a %-d %b, %H:%M UTC")
    end

    def result_label(match)
      case match["status"]
      when "POSTPONED"
        "Postponed"
      when "CANCELLED"
        "Cancelled"
      when "IN_PLAY", "PAUSED"
        home = match.dig("score", "fullTime", "home")
        away = match.dig("score", "fullTime", "away")
        home.nil? || away.nil? ? "In progress" : "#{home}–#{away} *(live)*"
      when *PLAYED_STATUSES
        home = match.dig("score", "fullTime", "home")
        away = match.dig("score", "fullTime", "away")
        home.nil? || away.nil? ? "—" : "#{home}–#{away}"
      else
        # Not played yet. Showing the kickoff beats a bare dash while the
        # round is still in progress — La Liga rounds can sprawl over a
        # fortnight, so "still to come" is genuinely useful information.
        utc = parse_time(match["utcDate"])
        return "—" if utc.blank?

        local = utc.in_time_zone(@timezones.first)
        "#{local.strftime("%-d %b, %-I:%M %p")} #{local.zone}"
      end
    rescue ArgumentError, TypeError
      "—"
    end

    def parse_time(value)
      return nil if value.blank?

      Time.parse(value).utc
    rescue ArgumentError, TypeError
      nil
    end
  end
end
