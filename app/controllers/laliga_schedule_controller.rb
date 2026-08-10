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

    # First request before the scheduled job has ever run — build it now so
    # the page isn't empty on install.
    cached ||= ::Jobs::LaligaScheduleCache.refresh! if SiteSetting.laliga_matchday_api_key.present?

    if cached
      render json: cached
    else
      render json: { error: "no_data_yet" }, status: 202
    end
  end
end
