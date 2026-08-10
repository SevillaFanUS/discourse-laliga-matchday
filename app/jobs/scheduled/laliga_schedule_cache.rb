# frozen_string_literal: true

module ::Jobs
  # Refreshes the cached season schedule served at
  # /laliga-schedule/data.json.
  #
  # Prototype note: this caches into PluginStore rather than a real table.
  # That's enough to render the view and see how it feels; a proper
  # laliga_matches table (with change detection for "kickoff times
  # confirmed" announcements) is the follow-up if the view earns its keep.
  class LaligaScheduleCache < ::Jobs::Scheduled
    every 6.hours

    CACHE_KEY = "schedule_cache"

    def execute(_args)
      return unless SiteSetting.laliga_matchday_enabled
      return if SiteSetting.laliga_matchday_api_key.blank?

      self.class.refresh!
    rescue => e
      Rails.logger.error("[#{::LaligaMatchday::PLUGIN_NAME}] schedule cache failed: #{e.class}: #{e.message}")
    end

    def self.refresh!
      competition = SiteSetting.laliga_matchday_competition_code.presence || "PD"
      season = resolved_season

      client = ::LaligaMatchday::FootballDataClient.new(SiteSetting.laliga_matchday_api_key)
      payload = client.season_matches(competition: competition, season: season)
      matches = payload && payload["matches"]

      if matches.blank?
        Rails.logger.warn("[#{::LaligaMatchday::PLUGIN_NAME}] schedule refresh returned no matches")
        return nil
      end

      data =
        ::LaligaMatchday::ScheduleBuilder.new(
          team_id: SiteSetting.laliga_matchday_team_id,
          season: season,
          competition: competition,
        ).build(matches)

      PluginStore.set(::LaligaMatchday::PLUGIN_NAME, CACHE_KEY, data)
      data
    end

    def self.resolved_season
      override = SiteSetting.laliga_matchday_season
      return override if override.present?

      now = Time.zone.now
      (now.month >= 6 ? now.year : now.year - 1).to_s
    end
  end
end
