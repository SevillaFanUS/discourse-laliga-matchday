# frozen_string_literal: true

require "set"

module ::LaligaMatchday
  # Orchestrates one poll: fetch, work out what is new, post it.
  #
  # State lives in the PluginStore keyed by the provider's event id, so a
  # restart mid-match resumes rather than re-announcing four goals.
  class LiveService
    STATE_KEY = "live_state"

    # Start following a match this long before kickoff, so the thread
    # exists and kick off can be announced on time.
    LEAD_MINUTES = 10

    # Keep polling this long after the final whistle: ESPN sometimes adds
    # the last card or a correction a minute or two late.
    TRAIL_MINUTES = 8

    def self.enabled?
      SiteSetting.laliga_live_enabled && SiteSetting.laliga_live_team_id.present?
    end

    # True when a match is close enough to justify the 30-second cadence.
    # Cheap: reads cached state, no network.
    def self.active?
      state = read_state
      return false if state["window_until"].blank?

      Time.parse(state["window_until"]) > Time.zone.now
    rescue StandardError
      false
    end

    def self.poll!
      return :disabled unless enabled?

      source =
        ::LaligaMatchday::LiveSource.new(
          source: SiteSetting.laliga_live_source,
          league: SiteSetting.laliga_live_league,
        )

      payload = source.scoreboard(Time.zone.now)
      return :fetch_failed if payload.nil?

      match = ::LaligaMatchday::LiveSource.find_match(payload, SiteSetting.laliga_live_team_id)

      if match.nil?
        clear_window
        return :no_match
      end

      new(match).run
    end

    def self.read_state
      PluginStore.get(::LaligaMatchday::PLUGIN_NAME, STATE_KEY) || {}
    end

    def self.write_state(state)
      PluginStore.set(::LaligaMatchday::PLUGIN_NAME, STATE_KEY, state)
    end

    def self.clear_window
      state = read_state
      return if state["window_until"].blank?

      state.delete("window_until")
      write_state(state)
    end

    def initialize(match)
      @match = match
      @event_id = match["id"].to_s
      @state = self.class.read_state
      @match_state = @state[@event_id] ||= { "announced" => [], "status" => nil }
    end

    def run
      status = ::LaligaMatchday::LiveReporter.status(@match)

      refresh_window(status)

      return :too_early if status[:state] == "pre" && !within_lead?

      topic_id = ensure_topic
      return :no_topic if topic_id.nil?

      ensure_live_post(topic_id)
      announce_new_events(status)
      update_live_post

      persist
      status[:completed] ? :finished : :updated
    end

    private

    # Widens the polling window whenever the match is live, so the
    # every-minute job knows to schedule its 30-second follow-up without
    # having to fetch anything itself.
    def refresh_window(status)
      until_time =
        if status[:state] == "in"
          Time.zone.now + LiveService::TRAIL_MINUTES.minutes
        elsif status[:state] == "pre" && within_lead?
          kickoff_at ? kickoff_at + 3.hours : Time.zone.now + 30.minutes
        elsif status[:completed]
          Time.zone.now + LiveService::TRAIL_MINUTES.minutes
        end

      @state["window_until"] = until_time.iso8601 if until_time
    end

    def kickoff_at
      value = @match["date"] || Array(@match["competitions"]).first&.dig("date")
      value && Time.parse(value.to_s)
    rescue StandardError
      nil
    end

    def within_lead?
      at = kickoff_at
      return false if at.nil?

      Time.zone.now >= at - LiveService::LEAD_MINUTES.minutes
    end

    # Three ways to land on a topic, in order of preference:
    #
    #   1. laliga_live_topic_id, if an admin has pinned one explicitly
    #   2. the matchday preview topic covering today, when the target is
    #      "matchday" — the thread people are already reading
    #   3. a topic of its own
    #
    # Falling back rather than failing matters: the preview only exists
    # if the preview job ran, and a missing thread should not cost a
    # match's coverage.
    def ensure_topic
      forced = SiteSetting.laliga_live_topic_id.to_i
      return forced if forced.positive?

      if SiteSetting.laliga_live_target.to_s == "matchday"
        existing = @match_state["topic_id"]
        return existing if existing.present? && Topic.exists?(id: existing, deleted_at: nil)

        found = ::LaligaMatchday::MatchdayService.topic_for(kickoff_at || Time.zone.now)

        if found
          @match_state["topic_id"] = found
          @match_state["joined"] = true
          return found
        end

        Rails.logger.info(
          "[#{::LaligaMatchday::PLUGIN_NAME}] no matchday topic covers this match; using its own",
        )
      end

      own_topic
    end

    def own_topic
      existing = @match_state["topic_id"]
      return existing if existing.present? && Topic.exists?(id: existing, deleted_at: nil)

      post =
        PostCreator.create!(
          Discourse.system_user,
          title: topic_title,
          raw: ::LaligaMatchday::LiveReporter.opening_post(@match, kickoff_line: kickoff_line),
          category: SiteSetting.laliga_matchday_category_id.to_i.presence,
          tags: SiteSetting.laliga_live_tags.to_s.split(",").map(&:strip).reject(&:empty?),
          skip_validations: true,
        )

      @match_state["topic_id"] = post.topic_id
      # The topic's own first post is the scoreline when we created it.
      @match_state["post_id"] = post.id
      @match_state["joined"] = false
      post.topic_id
    rescue => e
      Rails.logger.error("[#{::LaligaMatchday::PLUGIN_NAME}] could not create live topic: #{e.message}")
      nil
    end

    # The running scoreline lives in a post this plugin owns. In a topic
    # of our own that is the opening post; in somebody else's matchday
    # thread it has to be a reply, because the first post there is the
    # preview — fixtures and the table — and overwriting it would delete
    # the thing people opened the thread for.
    def ensure_live_post(topic_id)
      existing = @match_state["post_id"]
      return if existing.present? && Post.exists?(id: existing, deleted_at: nil)

      post =
        PostCreator.create!(
          Discourse.system_user,
          topic_id: topic_id.to_i,
          raw: ::LaligaMatchday::LiveReporter.opening_post(@match, kickoff_line: kickoff_line),
          skip_validations: true,
        )

      @match_state["post_id"] = post.id
      @match_state["digest"] = nil
    rescue => e
      Rails.logger.error(
        "[#{::LaligaMatchday::PLUGIN_NAME}] could not create the live scoreline post: #{e.message}",
      )
    end

    def topic_title
      s = ::LaligaMatchday::LiveReporter.sides(@match)
      home = s[:home].dig("team", "displayName")
      away = s[:away].dig("team", "displayName")
      date = kickoff_at ? kickoff_at.in_time_zone(timezone).strftime("%-d %b %Y") : nil

      ["#{home} v #{away}", "Live", date].compact.join(" — ")
    end

    def kickoff_line
      return nil if kickoff_at.nil?

      "Kick off #{kickoff_at.in_time_zone(timezone).strftime("%A %-d %B, %-I:%M %p %Z")}"
    end

    def timezone
      SiteSetting.laliga_matchday_timezones.to_s.split(",").first.presence || "Europe/Madrid"
    end

    def allowed_kinds
      SiteSetting.laliga_live_announce.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def announce_new_events(status)
      events = ::LaligaMatchday::LiveReporter.events(@match)
      events += lifecycle_events(status)

      announced = Array(@match_state["announced"])

      retracted =
        ::LaligaMatchday::LiveReporter.retracted(events, announced)

      retracted.each do |key|
        ghost = rebuild_from_key(key)
        post_reply(::LaligaMatchday::LiveReporter.disallowed_reply(ghost))
        announced.delete(key)
        announced << "retracted|#{key}"
      end

      fresh =
        ::LaligaMatchday::LiveReporter.unannounced(events, announced, allowed_kinds)

      fresh.each do |event|
        # Recorded before posting, not after: a duplicate goal announcement
        # is far worse than a missed one, and a crash between the two has
        # to fail in the safe direction.
        announced << event.key
        @match_state["announced"] = announced
        persist

        post_reply(::LaligaMatchday::LiveReporter.reply_for(event, @match))
      end

      @match_state["announced"] = announced
    end

    def rebuild_from_key(key)
      kind, minute, team_id, player = key.split("|")
      names = ::LaligaMatchday::LiveReporter.team_names(@match)

      ::LaligaMatchday::MatchEvent.new(
        kind: kind.to_sym,
        minute: minute,
        team_id: team_id,
        team_name: names[team_id.to_s],
        player: player,
      )
    end

    # Kick off, half time and full time are not in the details array;
    # they are transitions of the match status.
    def lifecycle_events(status)
      previous = @match_state["status"]
      detail = status[:detail].to_s
      events = []

      if status[:state] == "in" && previous.blank?
        events << ::LaligaMatchday::MatchEvent.new(kind: :kickoff, key: "kickoff|#{@event_id}")
      end

      if detail =~ /\bHT\b|half.?time/i
        events << ::LaligaMatchday::MatchEvent.new(kind: :half_time, key: "half_time|#{@event_id}")
      end

      if status[:completed]
        events << ::LaligaMatchday::MatchEvent.new(kind: :full_time, key: "full_time|#{@event_id}")
      end

      @match_state["status"] = status[:state]
      events
    end

    def post_reply(raw)
      topic_id = @match_state["topic_id"] || SiteSetting.laliga_live_topic_id.to_i
      return if topic_id.to_i <= 0

      PostCreator.create!(
        Discourse.system_user,
        topic_id: topic_id.to_i,
        raw: raw,
        skip_validations: true,
      )
    rescue => e
      # max_consecutive_replies is the likely culprit if this ever fires;
      # the system user should be exempt as both staff and topic owner,
      # but it is worth naming rather than failing quietly.
      Rails.logger.error(
        "[#{::LaligaMatchday::PLUGIN_NAME}] live reply rejected: #{e.class}: #{e.message}",
      )
    end

    def update_live_post
      post_id = @match_state["post_id"]
      return if post_id.blank?

      post = Post.find_by(id: post_id, deleted_at: nil)
      return if post.nil?

      body = ::LaligaMatchday::LiveReporter.opening_post(@match, kickoff_line: kickoff_line)
      digest = Digest::MD5.hexdigest(body)
      return if @match_state["digest"] == digest

      PostRevisor.new(post, post.topic).revise!(
        Discourse.system_user,
        { raw: body },
        skip_validations: true,
        bypass_bump: true,
        edit_reason: "Live score",
      )

      @match_state["digest"] = digest
    rescue => e
      Rails.logger.warn("[#{::LaligaMatchday::PLUGIN_NAME}] could not update live post: #{e.message}")
    end

    def persist
      @state[@event_id] = @match_state
      self.class.write_state(@state)
    end
  end
end
