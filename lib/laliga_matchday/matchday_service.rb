# frozen_string_literal: true

require "digest"

module ::LaligaMatchday
  # Works out which matchday (if any) is due a preview or a review right
  # now, and posts it.
  #
  # Matchday boundaries are derived from the fixtures themselves rather
  # than from the API's `currentMatchday`, because La Liga rounds sprawl
  # across Friday–Monday, midweek rounds exist, and postponements move
  # individual games out of their round. First/last kickoff per matchday
  # is the honest signal.
  class MatchdayService
    # A round counts as "done" once no match in it is still pending. A
    # postponed game is treated as resolved for this purpose, otherwise a
    # single deferred fixture would block the review indefinitely.
    RESOLVED_STATUSES = %w[FINISHED AWARDED POSTPONED CANCELLED SUSPENDED].freeze

    PLAYED_STATUSES = %w[FINISHED AWARDED].freeze

    # How far back to keep syncing a round's live results post. Long
    # enough to cover a sprawling round (matchday 1 of 2026/27 runs
    # 15–27 August), short enough that installing mid-season doesn't
    # backfill the whole year.
    REVIEW_WINDOW_DAYS = 21

    # Wait a little after the last final whistle before declaring a round
    # complete, so late score corrections land first.
    REVIEW_SETTLE_HOURS = 2

    def initialize
      @competition = SiteSetting.laliga_matchday_competition_code.presence || "PD"
      @season = resolved_season
      @team_id = SiteSetting.laliga_matchday_team_id.to_s
      @client = FootballDataClient.new(SiteSetting.laliga_matchday_api_key)
    end

    def run!(now: Time.zone.now)
      return unless configured?

      rounds = fetch_rounds
      return if rounds.blank?

      post_preview(rounds, now) if SiteSetting.laliga_matchday_post_preview
      sync_reviews(rounds, now) if SiteSetting.laliga_matchday_post_review
    end

    # Handy for checking output from the rails console without posting:
    #   LaligaMatchday::MatchdayService.new.dry_run(:preview, 28)
    def dry_run(kind, matchday)
      rounds = fetch_rounds
      round = rounds[matchday.to_i]
      return "No fixtures found for matchday #{matchday}" if round.blank?

      case kind.to_sym
      when :preview
        builder.preview_body(
          matchday: round[:matchday],
          matches: round[:matches],
          standings: fetch_standings,
          season_label: season_label,
        )
      when :review
        builder.review_body(
          matchday: round[:matchday],
          matches: round[:matches],
          standings: fetch_standings,
          scorers: fetch_scorers,
          season_label: season_label,
        )
      else
        "Unknown kind: #{kind} (expected :preview or :review)"
      end
    end

    private

    def configured?
      return false if SiteSetting.laliga_matchday_api_key.blank?
      return false if SiteSetting.laliga_matchday_category_id.to_i <= 0

      true
    end

    def resolved_season
      override = SiteSetting.laliga_matchday_season
      return override if override.present?

      now = Time.zone.now
      (now.month >= 6 ? now.year : now.year - 1).to_s
    end

    def season_label
      start_year = @season.to_i
      "#{start_year}/#{(start_year + 1).to_s[-2..]}"
    end

    def builder
      @builder ||=
        PostBuilder.new(
          team_id: @team_id,
          timezones: SiteSetting.laliga_matchday_timezones.to_s.split(",").map(&:strip).reject(&:blank?),
          standings_rows: SiteSetting.laliga_matchday_standings_rows.to_i,
          competition_label: competition_label,
        )
    end

    def competition_label
      @competition == "PD" ? "La Liga" : @competition
    end

    # => { 28 => { matchday:, matches:, first_kickoff:, last_kickoff:, resolved: } }
    def fetch_rounds
      payload = @client.season_matches(competition: @competition, season: @season)
      matches = payload && payload["matches"]
      return {} if matches.blank?

      matches
        .group_by { |m| m["matchday"] }
        .each_with_object({}) do |(matchday, round_matches), acc|
          next if matchday.blank?

          kickoffs = round_matches.filter_map { |m| parse_time(m["utcDate"]) }.sort

          acc[matchday.to_i] = {
            matchday: matchday.to_i,
            matches: round_matches.sort_by { |m| parse_time(m["utcDate"]) || Time.at(0).utc },
            first_kickoff: kickoffs.first,
            last_kickoff: kickoffs.last,
            resolved: round_matches.all? { |m| RESOLVED_STATUSES.include?(m["status"]) },
          }
        end
    end

    def fetch_standings
      payload = @client.standings(competition: @competition, season: @season)
      return nil if payload.blank?
      return nil if standings_stale?(payload)

      total = (payload["standings"] || []).find { |s| s["type"] == "TOTAL" }
      total && total["table"]
    end

    # Before a season kicks off, football-data.org returns the previous
    # season's completed table wrapped in the *new* season's metadata. A
    # preview post that embeds it would tell readers every club has already
    # played 38 games on matchday 1, so drop it instead — PostBuilder
    # simply omits the table section when standings are nil.
    def standings_stale?(payload)
      table = payload.dig("standings", 0, "table")
      return true if table.blank?

      season = payload["season"] || {}

      start_date =
        begin
          season["startDate"].present? ? Date.parse(season["startDate"].to_s) : nil
        rescue ArgumentError, TypeError
          nil
        end
      return true if start_date && start_date > Date.current

      current_matchday = season["currentMatchday"].to_i
      max_played = table.map { |row| row["playedGames"].to_i }.max.to_i

      current_matchday.positive? && max_played > current_matchday + 1
    end

    def fetch_scorers
      payload = @client.scorers(competition: @competition, season: @season, limit: 10)
      payload && payload["scorers"]
    end

    # --- preview ----------------------------------------------------------

    def post_preview(rounds, now)
      already = posted_matchdays("previewed_matchdays")
      window = SiteSetting.laliga_matchday_preview_hours_before.to_i.hours

      candidate =
        rounds
          .values
          .reject { |r| already.include?(r[:matchday]) }
          .select { |r| r[:first_kickoff].present? }
          .select { |r| r[:first_kickoff] > now && r[:first_kickoff] <= now + window }
          .min_by { |r| r[:first_kickoff] }

      return if candidate.blank?

      body =
        builder.preview_body(
          matchday: candidate[:matchday],
          matches: candidate[:matches],
          standings: fetch_standings,
          season_label: season_label,
        )

      create_topic(
        title: builder.preview_title(matchday: candidate[:matchday], season_label: season_label),
        raw: body,
      )

      mark_posted("previewed_matchdays", candidate[:matchday])
    end

    # --- review -----------------------------------------------------------

    # The review is a single live post per matchday rather than a one-shot
    # summary. It goes up as soon as the first match of the round
    # finishes, then gets edited in place as the rest come in.
    #
    # This exists because La Liga rounds sprawl: matchday 1 of 2026/27
    # runs 15–27 August. Waiting for every match to resolve would put the
    # results post two weeks behind, arriving after matchday 2 and 3 had
    # already been previewed. Several rounds can be mid-flight at once, so
    # this syncs all eligible rounds, not just one.
    def sync_reviews(rounds, now)
      state = review_state

      eligible = rounds.values.select { |round| review_eligible?(round, now, state) }
      return if eligible.empty?

      # Only pay for these once per run, however many rounds are active.
      standings = fetch_standings
      scorers = fetch_scorers

      eligible.each { |round| sync_review(round, standings, scorers, now, state) }

      write_review_state(state)
    end

    def review_eligible?(round, now, state)
      return false if round[:first_kickoff].blank?
      return false if round[:first_kickoff] > now

      # Finished rounds stay put — no need to keep re-rendering them.
      entry = state[round[:matchday].to_s]
      return false if entry && entry["complete"]

      # Don't reach back and start posting reviews for an entire season on
      # first install.
      return false if round[:first_kickoff] < now - REVIEW_WINDOW_DAYS.days

      round[:matches].any? { |m| PLAYED_STATUSES.include?(m["status"]) }
    end

    def sync_review(round, standings, scorers, now, state)
      matchday = round[:matchday]
      key = matchday.to_s
      entry = state[key] || {}

      complete = round[:resolved] && round[:last_kickoff].present? &&
        round[:last_kickoff] < now - REVIEW_SETTLE_HOURS.hours

      body =
        builder.review_body(
          matchday: matchday,
          matches: round[:matches],
          standings: standings,
          scorers: scorers,
          season_label: season_label,
          complete: complete,
          updated_at: now,
        )

      # The "updated" timestamp changes every run, so it's excluded from
      # the fingerprint — otherwise every check would look like a change
      # and the post would be rewritten hourly for no reason.
      digest = Digest::MD5.hexdigest(body.sub(/^\*.*\*$/, ""))

      if entry["post_id"].blank?
        post = create_topic(title: builder.review_title(matchday: matchday, season_label: season_label), raw: body)
        state[key] = { "topic_id" => post.topic_id, "post_id" => post.id, "digest" => digest, "complete" => complete }
        return
      end

      return if entry["digest"] == digest && entry["complete"] == complete

      # Silent edit while the round is in progress; bump when it goes
      # final so the completed results resurface once.
      became_final = complete && !entry["complete"]
      update_post(entry["post_id"], body, bump: became_final)

      state[key] = entry.merge("digest" => digest, "complete" => complete)
    end

    def update_post(post_id, body, bump:)
      post = Post.find_by(id: post_id)
      if post.nil?
        Rails.logger.warn("[#{::LaligaMatchday::PLUGIN_NAME}] review post #{post_id} is gone; skipping update")
        return
      end

      PostRevisor.new(post, post.topic).revise!(
        Discourse.system_user,
        { raw: body },
        skip_validations: true,
        bypass_bump: !bump,
        edit_reason: "Results updated",
      )
    end

    def review_state
      PluginStore.get(::LaligaMatchday::PLUGIN_NAME, state_key("reviews")) || {}
    end

    def write_review_state(state)
      PluginStore.set(::LaligaMatchday::PLUGIN_NAME, state_key("reviews"), state)
    end

    # --- posting / state --------------------------------------------------

    def create_topic(title:, raw:)
      PostCreator.create!(
        Discourse.system_user,
        title: title,
        raw: raw,
        category: SiteSetting.laliga_matchday_category_id.to_i,
        tags: tags,
        skip_validations: true,
      )
    rescue => e
      Rails.logger.error("[#{::LaligaMatchday::PLUGIN_NAME}] failed to create topic #{title.inspect}: #{e.message}")
      raise
    end

    def tags
      SiteSetting.laliga_matchday_tags.to_s.split(",").map(&:strip).reject(&:blank?)
    end

    def posted_matchdays(key)
      stored = PluginStore.get(::LaligaMatchday::PLUGIN_NAME, state_key(key))
      Array(stored).map(&:to_i)
    end

    def mark_posted(key, matchday)
      updated = (posted_matchdays(key) + [matchday.to_i]).uniq.sort
      PluginStore.set(::LaligaMatchday::PLUGIN_NAME, state_key(key), updated)
    end

    # Namespaced per competition+season so a new season starts with a clean
    # slate instead of thinking matchday 1 was already posted last year.
    def state_key(key)
      "#{key}_#{@competition}_#{@season}"
    end

    def parse_time(value)
      return nil if value.blank?

      Time.parse(value).utc
    rescue ArgumentError, TypeError
      nil
    end
  end
end
