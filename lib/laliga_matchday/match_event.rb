# frozen_string_literal: true

module ::LaligaMatchday
  # One thing that happened in a match, normalised from the `details`
  # array that ESPN embeds in each scoreboard event.
  #
  # Using the scoreboard's own details rather than the separate
  # play-by-play endpoint means score and events arrive in a single
  # request, and there is no second host that can fail on its own.
  class MatchEvent
    KINDS = %i[
      goal own_goal penalty_goal penalty_missed yellow red second_yellow
      substitution var other kickoff half_time full_time
    ].freeze

    SCORING = %i[goal own_goal penalty_goal].freeze

    attr_reader :kind, :minute, :team_id, :team_name, :player, :text, :home_score, :away_score

    def initialize(
      kind:,
      minute: nil,
      team_id: nil,
      team_name: nil,
      player: nil,
      text: nil,
      home_score: nil,
      away_score: nil,
      key: nil
    )
      @kind = kind
      @minute = minute
      @team_id = team_id.to_s
      @team_name = team_name
      @player = player
      @text = text
      @home_score = home_score
      @away_score = away_score
      @key = key
    end

    # Stable across polls. The details array carries no id of its own, so
    # the key is built from the fields that do not change once an event
    # has happened. Including the athlete matters: two yellows in the
    # same minute for the same side are otherwise indistinguishable.
    def key
      @key ||= [kind, minute, team_id, player].map(&:to_s).join("|")
    end

    def scoring?
      SCORING.include?(kind)
    end

    def lifecycle?
      %i[kickoff half_time full_time].include?(kind)
    end

    # Builds from one entry of competitions[0].details.
    def self.from_detail(detail, teams)
      return nil unless detail.is_a?(Hash)

      team_id = detail.dig("team", "id").to_s
      athlete = Array(detail["athletesInvolved"]).first
      type_text = detail.dig("type", "text").to_s

      new(
        kind: classify(detail, type_text),
        minute: detail.dig("clock", "displayValue"),
        team_id: team_id,
        team_name: teams[team_id],
        player: athlete && (athlete["displayName"] || athlete["shortName"]),
        text: type_text,
      )
    end

    # Order matters. An own goal and a penalty are both scoring plays, and
    # a second yellow arrives flagged as a red, so the more specific test
    # has to come first in each case.
    def self.classify(detail, type_text)
      lowered = type_text.downcase

      if detail["scoringPlay"]
        return :own_goal if detail["ownGoal"]
        return :penalty_goal if detail["penaltyKick"]

        return :goal
      end

      return :penalty_missed if lowered.include?("penalty") && !detail["scoringPlay"]

      if detail["redCard"]
        return :second_yellow if lowered.include?("second") || lowered.include?("2nd")

        return :red
      end

      return :yellow if detail["yellowCard"]
      return :substitution if lowered.include?("substitution")
      return :var if lowered.include?("var") || lowered.include?("review")

      :other
    end
  end
end
