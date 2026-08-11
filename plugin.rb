# frozen_string_literal: true

# name: discourse-laliga-matchday
# about: Posts an automatic preview topic before each La Liga matchday (all fixtures, kickoff times, current table) and a review topic once the round finishes (results, updated standings, top scorers).
# version: 0.3.0
# authors: Chris Lail
# url: https://forum.monchismen.com

enabled_site_setting :laliga_matchday_enabled

module ::LaligaMatchday
  PLUGIN_NAME = "discourse-laliga-matchday"
end

after_initialize do
  # This Discourse install does not Zeitwerk-autoload plugin lib/ and app/
  # files, so every file has to be required explicitly here — same as
  # discourse-laliga-sidebar and discourse-sevilla-fixtures.
  require_relative "lib/laliga_matchday/football_data_client"
  require_relative "lib/laliga_matchday/post_builder"
  require_relative "lib/laliga_matchday/matchday_service"
  require_relative "lib/laliga_matchday/schedule_builder"
  require_relative "lib/laliga_matchday/ics_builder"
  require_relative "app/jobs/scheduled/laliga_matchday_sync"
  require_relative "app/jobs/scheduled/laliga_schedule_cache"
  require_relative "app/controllers/laliga_schedule_controller"

  Discourse::Application.routes.append do
    # Renders the Ember app shell so this is a real page with forum chrome;
    # the theme component paints the schedule into it.
    get "/laliga-schedule" => "laliga_schedule#index"
    get "/laliga-schedule/data.json" => "laliga_schedule#data"
    get "/laliga-schedule.ics" => "laliga_schedule#ics", :defaults => { format: "ics" }
  end
end
