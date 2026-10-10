# frozen_string_literal: true

module ::Jobs
  # The half-minute follow-up to LaligaLivePoll. One poll, then it stops
  # — scheduling the next one is the scheduled job's business, so this
  # cannot run away on its own.
  class LaligaLiveTick < ::Jobs::Base
    def execute(_args)
      return unless SiteSetting.laliga_live_enabled
      return unless ::LaligaMatchday::LiveService.active?

      ::LaligaMatchday::LiveService.poll!
    rescue => e
      Rails.logger.error("[#{::LaligaMatchday::PLUGIN_NAME}] live tick failed: #{e.class}: #{e.message}")
    end
  end
end
