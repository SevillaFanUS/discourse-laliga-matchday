# frozen_string_literal: true

# Fetches the real feed and prints exactly what would be posted, without
# posting anything or touching stored state.
#
#   bin/rails runner plugins/discourse-laliga-matchday/script/live_dry_run.rb
#   bin/rails runner plugins/discourse-laliga-matchday/script/live_dry_run.rb 20260920
#
# Safe to run during a live match. Run it once, wait a minute, run it
# again: the second run should show the same events, which is what
# deduplication will be doing for real.

date = ARGV[0] ? Time.strptime(ARGV[0], "%Y%m%d") : Time.zone.now

source =
  ::LaligaMatchday::LiveSource.new(
    source: SiteSetting.laliga_live_source,
    league: SiteSetting.laliga_live_league,
  )

team = SiteSetting.laliga_live_team_id

puts "source:  #{SiteSetting.laliga_live_source}"
puts "league:  #{SiteSetting.laliga_live_league}"
puts "team:    #{team}"
puts "date:    #{date.strftime("%Y-%m-%d")}"
puts

payload = source.scoreboard(date)

if payload.nil?
  puts "FAILED: #{source.last_error}"
  puts
  puts "Try the other source by changing laliga_live_source, or run"
  puts "script/live_probe.rb to compare both."
  exit 1
end

all = Array(payload["events"])
puts "#{all.size} matches in this league on that date"

match = ::LaligaMatchday::LiveSource.find_match(payload, team)

if match.nil?
  puts "No match involving team #{team}."
  puts "Fixtures found: " + all.map { |e| e["name"] }.join(", ") if all.any?
  exit 0
end

R = ::LaligaMatchday::LiveReporter
status = R.status(match)

puts
puts "match:   #{match["name"]} (event #{match["id"]})"
puts "status:  #{status[:state]} · #{status[:detail]} · clock #{status[:clock].inspect}"
puts "score:   #{R.scoreline(match)}"
puts

target = SiteSetting.laliga_live_topic_id.to_i
if target.positive?
  puts "would post into topic #{target} (pinned by laliga_live_topic_id)"
elsif SiteSetting.laliga_live_target.to_s == "matchday"
  at =
    begin
      Time.parse(match["date"].to_s)
    rescue StandardError
      Time.zone.now
    end
  found = ::LaligaMatchday::MatchdayService.topic_for(at)
  if found
    puts "would post into the matchday topic #{found}"
  else
    puts "no matchday topic covers this match — would create its own"
    puts "(the preview job records topics from now on; rounds previewed"
    puts " before this upgrade have no stored id)"
  end
else
  puts "would create a topic of its own (laliga_live_target = own)"
end
puts

puts "--- the running scoreline post would read ---"
puts R.opening_post(match)
puts

events = R.events(match)
puts "--- #{events.size} events in the feed ---"
events.each do |e|
  puts format("  %-6s %-16s %-22s %s", e.minute, e.kind, e.player.to_s[0, 22], e.key)
end
puts

allowed = SiteSetting.laliga_live_announce.to_s.split(",").map(&:strip)
announce = R.unannounced(events, [], allowed)

puts "--- #{announce.size} of those would be posted as replies ---"
puts "    (policy: #{allowed.join(", ")})"
puts
announce.each do |e|
  puts R.reply_for(e, match)
  puts
end

skipped = events.size - announce.size
puts "#{skipped} event(s) filtered out by the announce policy." if skipped.positive?

stored = ::LaligaMatchday::LiveService.read_state[match["id"].to_s]
if stored
  puts
  puts "Stored state for this match already exists:"
  puts "  topic #{stored["topic_id"].inspect}, #{Array(stored["announced"]).size} events announced"
  puts "  A real run would post only what is not in that list."
end
