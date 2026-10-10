# frozen_string_literal: true

# Compares the two candidate sources for live scores and match events,
# from this server, and reports which can be reached and how fresh each
# is.
#
#   bin/rails runner plugins/discourse-laliga-matchday/script/live_probe.rb
#   bin/rails runner plugins/discourse-laliga-matchday/script/live_probe.rb 20260920
#
# ESPN appears to be the upstream that worldcup26.ir mirrors, so the
# question is not which has better data. It is which this server can
# reach, and whether the mirror is fresh enough to justify the extra hop.

require "net/http"
require "json"
require "time"

date = ARGV[0] || Time.now.utc.strftime("%Y%m%d")
LEAGUE = "esp.1"
PAD = " " * 36

def get(label, url)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = 10
  http.read_timeout = 20

  request = Net::HTTP::Get.new(uri)
  request["Accept"] = "application/json"
  request["User-Agent"] = "discourse-laliga-matchday"

  started = Time.now
  response = http.request(request)
  elapsed = ((Time.now - started) * 1000).round

  body = response.body.to_s
  puts format("  %-34s HTTP %-4s %7d bytes %6dms", label, response.code, body.length, elapsed)

  return nil unless response.is_a?(Net::HTTPSuccess)

  if body.strip.empty?
    puts "#{PAD}empty body"
    return nil
  end

  JSON.parse(body)
rescue JSON::ParserError
  puts "#{PAD}not JSON: #{body[0, 120].inspect}"
  nil
rescue => e
  puts format("  %-34s %s: %s", label, e.class, e.message)
  nil
end

def summarise(payload)
  return if payload.nil?

  events = payload["events"] || []
  puts "#{PAD}#{events.size} matches"

  events.first(4).each do |event|
    comp = Array(event["competitions"]).first || {}
    status = comp.dig("status", "type") || {}
    sides = Array(comp["competitors"])
    home = sides.find { |c| c["homeAway"] == "home" }
    away = sides.find { |c| c["homeAway"] == "away" }

    fixture = "#{home&.dig("team", "displayName")} v #{away&.dig("team", "displayName")}"
    puts format(
      "%s%-30s %s-%s  %s",
      PAD,
      fixture[0, 30],
      home && home["score"],
      away && away["score"],
      status["detail"] || status["name"],
    )
  end
end

puts "date: #{date}   league: #{LEAGUE}"
puts

puts "worldcup26.ir (mirror)"
meta = get("meta", "https://worldcup26.ir/get/soccer/meta")
if meta
  synced = meta["lastSuccessfulSyncAt"]
  if synced
    age = (Time.now.utc - Time.parse(synced)).round
    puts "#{PAD}last sync #{synced} (#{age}s ago)"
  end
  puts "#{PAD}#{meta.dig("coverage", "playByPlayEvents")} stored play events, " \
         "#{meta.dig("coverage", "competitions")} competitions"
end

mirror = get("scoreboard", "https://worldcup26.ir/get/soccer/#{LEAGUE}/scoreboard?dates=#{date}")
summarise(mirror)

puts
puts "site.api.espn.com (direct)"
espn = get(
  "scoreboard",
  "https://site.api.espn.com/apis/site/v2/sports/soccer/#{LEAGUE}/scoreboard?dates=#{date}",
)
summarise(espn)

# Play-by-play is what the live-events feature actually needs, and it
# lives on a different host to the scoreboard, so probe it separately
# rather than assume it follows.
event_id = (espn || mirror)&.dig("events", 0, "id")

if event_id
  puts
  puts "play-by-play for event #{event_id}"
  plays = get(
    "espn core plays",
    "https://sports.core.api.espn.com/v2/sports/soccer/leagues/#{LEAGUE}/events/#{event_id}/competitions/#{event_id}/plays?limit=25",
  )
  puts "#{PAD}#{Array(plays && plays["items"]).size} plays returned" if plays

  mirror_plays = get(
    "mirror plays",
    "https://worldcup26.ir/get/soccer/#{LEAGUE}/events/#{event_id}/plays",
  )
  if mirror_plays
    list = mirror_plays["items"] || mirror_plays["plays"] || mirror_plays["data"]
    puts "#{PAD}#{Array(list).size} plays returned"
    puts "#{PAD}keys: #{mirror_plays.keys.join(", ")}"
  end
else
  puts
  puts "No event id available for that date, so play-by-play was not probed."
  puts "Re-run with a date that has La Liga fixtures: live_probe.rb 20260920"
end

puts
puts "Reading the result:"
puts "  both reachable        -> use ESPN directly, keep the mirror as a fallback setting"
puts "  only the mirror works -> ESPN is refusing this server, as its roster endpoint already does"
puts "  only ESPN works       -> skip the mirror entirely"
puts "  neither               -> the live-events feature cannot be built on these"
