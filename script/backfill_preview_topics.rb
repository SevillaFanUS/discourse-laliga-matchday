# frozen_string_literal: true

# Records the matchday preview topics that already exist, so live
# reporting can find them.
#
#   bin/rails runner plugins/discourse-laliga-matchday/script/backfill_preview_topics.rb
#   bin/rails runner plugins/discourse-laliga-matchday/script/backfill_preview_topics.rb --write
#
# Without --write it only reports. Matching is exact: each round's
# preview title is regenerated from the same builder that created it,
# then looked up. This uses the football-data API, so run it once rather
# than on a schedule.

write = ARGV.include?("--write")

service = ::LaligaMatchday::MatchdayService.new
rounds = service.send(:fetch_rounds)

if rounds.blank?
  puts "No rounds returned. Check laliga_matchday_api_key."
  exit 1
end

builder = service.send(:builder)
season_label = service.send(:season_label)
key = service.send(:state_key, "preview_topics")
stored = PluginStore.get(::LaligaMatchday::PLUGIN_NAME, key) || {}

category_id = SiteSetting.laliga_matchday_category_id.to_i

puts "#{rounds.size} rounds known, #{stored.size} already recorded"
puts

added = 0

rounds.values.sort_by { |r| r[:matchday].to_i }.each do |round|
  matchday = round[:matchday].to_s
  next if stored.key?(matchday)
  next if round[:first_kickoff].blank?

  title = builder.preview_title(matchday: round[:matchday], season_label: season_label)

  scope = Topic.where(deleted_at: nil, title: title)
  scope = scope.where(category_id: category_id) if category_id.positive?
  topic = scope.order(created_at: :asc).first

  if topic.nil?
    puts format("  %-4s no topic titled %p", matchday, title)
    next
  end

  puts format("  %-4s topic %-7s %s", matchday, topic.id, title)

  stored[matchday] = {
    "topic_id" => topic.id,
    "first_kickoff" => round[:first_kickoff]&.iso8601,
    "last_kickoff" => round[:last_kickoff]&.iso8601,
    "matched_by" => "backfill",
  }
  added += 1
end

puts
if added.zero?
  puts "Nothing to add."
elsif write
  PluginStore.set(::LaligaMatchday::PLUGIN_NAME, key, stored)
  puts "Recorded #{added} preview topic(s)."
else
  puts "Would record #{added} preview topic(s). Re-run with --write to save."
end
