# frozen_string_literal: true

require "digest"

module ::LaligaMatchday
  # Turns a live scoreboard into thread activity: a running scoreline in
  # the opening post, and a reply for each notable event as it happens.
  #
  # Everything that decides *what* to say lives here and takes plain
  # hashes, so script/live_check.rb can exercise it without Rails.
  class LiveReporter
    MARKS = {
      goal: "⚽",
      own_goal: "⚽",
      penalty_goal: "⚽",
      penalty_missed: "❌",
      yellow: "🟨",
      red: "🟥",
      second_yellow: "🟥",
      substitution: "🔄",
      var: "📺",
      kickoff: "▶️",
      half_time: "⏸️",
      full_time: "⏹️",
    }.freeze

    DEFAULT_KINDS = %w[
      goal own_goal penalty_goal penalty_missed red second_yellow
      kickoff half_time full_time
    ].freeze

    # --- reading the payload ------------------------------------------

    def self.sides(match)
      competition = Array(match["competitions"]).first || {}
      competitors = Array(competition["competitors"])

      home = competitors.find { |c| c["homeAway"] == "home" } || {}
      away = competitors.find { |c| c["homeAway"] == "away" } || {}

      { home: home, away: away }
    end

    def self.team_names(match)
      s = sides(match)
      {
        s[:home].dig("team", "id").to_s => s[:home].dig("team", "displayName"),
        s[:away].dig("team", "id").to_s => s[:away].dig("team", "displayName"),
      }
    end

    def self.status(match)
      competition = Array(match["competitions"]).first || {}
      type = competition.dig("status", "type") || {}

      {
        state: type["state"].to_s,
        completed: type["completed"] == true,
        detail: type["detail"] || type["shortDetail"] || type["name"],
        clock: competition.dig("status", "displayClock"),
      }
    end

    def self.scoreline(match)
      s = sides(match)
      home = s[:home]
      away = s[:away]

      "#{home.dig("team", "displayName")} #{home["score"]}–#{away["score"]} " \
        "#{away.dig("team", "displayName")}"
    end

    # Events, oldest first, with the running score attached to each
    # scoring event so a goal reply can state the score it produced.
    def self.events(match)
      competition = Array(match["competitions"]).first || {}
      names = team_names(match)
      s = sides(match)
      home_id = s[:home].dig("team", "id").to_s

      home = 0
      away = 0

      Array(competition["details"]).filter_map do |detail|
        event = ::LaligaMatchday::MatchEvent.from_detail(detail, names)
        next if event.nil?

        if event.scoring?
          # An own goal credits the other side.
          scored_for_home =
            if event.kind == :own_goal
              event.team_id != home_id
            else
              event.team_id == home_id
            end

          scored_for_home ? home += 1 : away += 1

          event =
            ::LaligaMatchday::MatchEvent.new(
              kind: event.kind,
              minute: event.minute,
              team_id: event.team_id,
              team_name: event.team_name,
              player: event.player,
              text: event.text,
              home_score: home,
              away_score: away,
              key: event.key,
            )
        end

        event
      end
    end

    # --- writing ------------------------------------------------------

    def self.opening_post(match, kickoff_line: nil)
      st = status(match)

      header =
        if st[:completed]
          "**Full time — #{scoreline(match)}**"
        elsif st[:state] == "in"
          "**#{scoreline(match)}** · #{st[:clock] || st[:detail]}"
        else
          "**#{scoreline(match)}**"
        end

      lines = [header, ""]
      lines << kickoff_line if kickoff_line
      lines << st[:detail].to_s if st[:detail].present?
      lines << ""
      lines << "*Updates automatically while the match is on.*"

      lines.compact.join("\n")
    end

    def self.reply_for(event, match)
      mark = MARKS[event.kind] || "•"
      minute = event.minute.present? ? "#{event.minute} " : ""

      case event.kind
      when :goal, :penalty_goal, :own_goal
        label =
          case event.kind
          when :penalty_goal then "GOAL (pen)"
          when :own_goal then "OWN GOAL"
          else "GOAL"
          end

        score = "#{event.home_score}–#{event.away_score}"
        who = event.player.present? ? " · #{event.player}" : ""
        "#{mark} **#{label} — #{teams_with_score(match, score)}**\n#{minute}#{event.team_name}#{who}"
      when :penalty_missed
        "#{mark} **Penalty missed — #{event.team_name}**\n#{minute}#{event.player}"
      when :red, :second_yellow
        label = event.kind == :second_yellow ? "Second yellow" : "Red card"
        "#{mark} **#{label} — #{event.team_name}**\n#{minute}#{event.player}"
      when :yellow
        "#{mark} Yellow — #{event.player} (#{event.team_name}) #{minute}".strip
      when :substitution
        "#{mark} Substitution — #{event.team_name} #{minute}#{event.player}".strip
      when :kickoff
        "#{mark} **Kick off** — #{scoreline(match).sub(/ \d+–\d+ /, " v ")}"
      when :half_time
        "#{mark} **Half time — #{scoreline(match)}**"
      when :full_time
        "#{mark} **Full time — #{scoreline(match)}**"
      else
        "#{mark} #{event.text} #{minute}".strip
      end
    end

    def self.teams_with_score(match, score)
      s = sides(match)
      "#{s[:home].dig("team", "displayName")} #{score} #{s[:away].dig("team", "displayName")}"
    end

    def self.disallowed_reply(event)
      "📺 **Goal disallowed** — #{event.team_name}#{event.player.present? ? " · #{event.player}" : ""}"
    end

    # --- deciding -----------------------------------------------------

    # New events, in order, filtered to the kinds the site wants
    # announced. Lifecycle events are synthesised by the caller from
    # status changes, so they arrive already in `current`.
    def self.unannounced(current, announced_keys, allowed_kinds)
      allowed = allowed_kinds.map(&:to_s)
      seen = announced_keys.to_set

      current.reject { |event| seen.include?(event.key) }.select do |event|
        allowed.include?(event.kind.to_s)
      end
    end

    # Scoring events that were announced and have since vanished, which
    # is what a VAR reversal looks like from the outside.
    def self.retracted(current, announced_keys)
      live = current.map(&:key).to_set

      announced_keys.select do |key|
        next false if live.include?(key)

        kind = key.split("|").first.to_s
        ::LaligaMatchday::MatchEvent::SCORING.map(&:to_s).include?(kind)
      end
    end
  end
end
