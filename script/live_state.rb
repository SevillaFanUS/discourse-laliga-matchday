# frozen_string_literal: true

# Shows what the live reporter has stored and which topic it would pick
# for a given moment. Changes nothing.
#
#   bin/rails runner plugins/discourse-laliga-matchday/script/live_state.rb
#   bin/rails runner plugins/discourse-laliga-matchday/script/live_state.rb 2026-10-18T19:00:00Z

require "time"

at = ARGV[0] ? Time.parse(ARGV[0]) : Time.zone.now

# Printed first because "the fix is not deployed" has now been the
# answer twice, and it is cheaper to see the version than to infer it
# from behaviour.
version = File.read(File.join(__dir__, "..", "plugin.rb"))[/^# version: (\S+)/, 1]
puts "plugin version: #{version}"
has_finder = File.exist?(File.join(__dir__, "..", "lib/laliga_matchday/fixture_topic_finder.rb"))
puts "fixture finder: #{has_finder ? "present" : "ABSENT — this build cannot use match threads"}"
puts

puts "settings"
puts "  laliga_live_enabled:  #{SiteSetting.laliga_live_enabled}"
puts "  laliga_live_target:   #{SiteSetting.laliga_live_target}"
puts "  laliga_live_topic_id: #{SiteSetting.laliga_live_topic_id}"
puts "  category:             #{SiteSetting.laliga_matchday_category_id}"
puts

service = ::LaligaMatchday::MatchdayService.new
key = service.send(:state_key, "preview_topics")
stored = PluginStore.get(::LaligaMatchday::PLUGIN_NAME, key) || {}

puts "stored preview topics (#{key})"
if stored.empty?
  puts "  NONE — this is why live updates started their own thread."
  puts "  Rounds previewed before this bookkeeping existed were never recorded."
  puts "  Run script/backfill_preview_topics.rb to fill them in."
else
  stored.each do |matchday, entry|
    topic = Topic.find_by(id: entry["topic_id"], deleted_at: nil)
    puts format(
      "  %-12s topic %-7s %s .. %s  %s",
      matchday,
      entry["topic_id"],
      entry["first_kickoff"],
      entry["last_kickoff"],
      topic ? topic.title : "(topic missing)",
    )
  end
end
puts

puts "fixture match threads (discourse-sevilla-fixtures)"
if ::LaligaMatchday::FixtureTopicFinder.available?
  column = ::LaligaMatchday::FixtureTopicFinder.date_column
  puts "  model present, date column: #{column.inspect}"
  if column
    near =
      SevillaFixture
        .where.not(discourse_topic_id: nil)
        .where("#{column} >= ? AND #{column} <= ?", at - 18 * 3600, at + 18 * 3600)
    puts "  #{near.count} fixture(s) with a thread within 18h of that time"
    near.each do |f|
      topic = Topic.find_by(id: f.discourse_topic_id)
      puts format("    topic %-7s %s v %s  %s", f.discourse_topic_id, f.home_team, f.away_team, topic&.title)
    end
  end
else
  puts "  SevillaFixture not available — the fixtures plugin is not installed,"
  puts "  so live updates will use the matchday preview instead."
end
puts

puts "resolution for #{at.iso8601}"
from_store = service.send(:from_store, at)
puts "  by stored map:   #{from_store.inspect}"
from_title = service.send(:from_titles, at)
puts "  by title search: #{from_title.inspect}"

chosen = from_store || from_title
if chosen
  topic = Topic.find_by(id: chosen)
  puts "  would post into: #{chosen} — #{topic&.title}"
else
  puts "  would post into: a new topic of its own"
end
puts

live = PluginStore.get(::LaligaMatchday::PLUGIN_NAME, ::LaligaMatchday::LiveService::STATE_KEY) || {}
puts "live match state"
if live.empty?
  puts "  nothing recorded yet"
else
  live.each do |event_id, entry|
    next unless entry.is_a?(Hash)

    topic = entry["topic_id"] && Topic.find_by(id: entry["topic_id"])
    puts format(
      "  event %-10s topic %-7s joined=%-5s announced=%-3s  %s",
      event_id,
      entry["topic_id"],
      entry["joined"].inspect,
      Array(entry["announced"]).size,
      topic&.title,
    )
  end
end
