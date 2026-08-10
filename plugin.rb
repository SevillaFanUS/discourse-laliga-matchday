# frozen_string_literal: true

# name: discourse-laliga-matchday
# about: Posts an automatic preview topic before each La Liga matchday (all fixtures, kickoff times, current table) and a review topic once the round finishes (results, updated standings, top scorers).
# version: 0.1.0
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
  require_relative "app/jobs/scheduled/laliga_matchday_sync"
end
