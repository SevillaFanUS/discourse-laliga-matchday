# frozen_string_literal: true

module ::Jobs
  # Runs hourly. The service itself decides whether anything is actually
  # due — an hourly check is frequent enough to hit the preview window
  # accurately without hammering the API (3 requests per run at most,
  # against a free-tier limit of 10/minute).
  class LaligaMatchdaySync < ::Jobs::Scheduled
    every 1.hour

    def execute(_args)
      return unless SiteSetting.laliga_matchday_enabled

      ::LaligaMatchday::MatchdayService.new.run!
    rescue => e
      Rails.logger.error(
        "[#{::LaligaMatchday::PLUGIN_NAME}] sync failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}",
      )
    end
  end
end
