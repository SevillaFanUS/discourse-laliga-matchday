# frozen_string_literal: true

module ::Jobs
  # Discourse's scheduler has one-minute granularity — there is no
  # `every 30.seconds`. So this runs every minute, polls once, and when a
  # match is actually in progress enqueues a single follow-up half a
  # minute later. Two polls a minute during a match.
  #
  # The follow-up never enqueues another follow-up. That is deliberate:
  # a self-perpetuating chain can outlive the match if a full-time
  # transition is ever missed, and a stuck chain polling forever is a
  # worse failure than a missed 30-second slot.
  class LaligaLivePoll < ::Jobs::Scheduled
    every 1.minute

    def execute(_args)
      return unless SiteSetting.laliga_live_enabled

      # Cheap guard: reads cached state, no network. Off matchday this
      # job costs a PluginStore read and nothing else.
      window_open = ::LaligaMatchday::LiveService.active?

      result = ::LaligaMatchday::LiveService.poll!

      if window_open || result == :updated
        Jobs.enqueue_in(30.seconds, :laliga_live_tick)
      end
    rescue => e
      Rails.logger.error("[#{::LaligaMatchday::PLUGIN_NAME}] live poll failed: #{e.class}: #{e.message}")
    end
  end
end
