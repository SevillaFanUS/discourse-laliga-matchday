# frozen_string_literal: true

class LaligaScheduleController < ::ApplicationController
  # Deliberately no `requires_plugin` macro — it caused loading trouble on
  # this install when building discourse-laliga-sidebar. The enabled check
  # lives in the action instead.
  skip_before_action :check_xhr, :preload_json, :redirect_to_login_if_required, only: [:data], raise: false

  # Renders the Ember application shell so /laliga-schedule is a real page
  # with normal forum chrome. The theme component takes over from there.
  def index
    render "default/empty"
  end

  def data
    unless SiteSetting.laliga_matchday_enabled
      render json: { error: "disabled" }, status: 404
      return
    end

    cached = PluginStore.get(::LaligaMatchday::PLUGIN_NAME, ::Jobs::LaligaScheduleCache::CACHE_KEY)

    # Discard a payload written by an older version of the serializer —
    # without this, a deploy that changes the shape keeps serving stale
    # data until the 6-hourly job next runs. PluginStore round-trips
    # through JSON, so keys come back as strings.
    outdated = cached && cached["schema_version"].to_i != ::LaligaMatchday::ScheduleBuilder::SCHEMA_VERSION
    fallback = outdated ? cached : nil
    cached = nil if outdated

    # Also covers the first request after install, before the scheduled
    # job has ever run.
    cached ||= ::Jobs::LaligaScheduleCache.refresh! if SiteSetting.laliga_matchday_api_key.present?

    # If the rebuild failed (API down, rate limited), an outdated payload
    # still beats an empty page.
    cached ||= fallback

    if cached
      render json: cached
    else
      render json: { error: "no_data_yet" }, status: 202
    end
  end
end
