# frozen_string_literal: true

# Replays a whole match through the live reporter, poll by poll, with no
# Rails, no network and no database:
#
#   ruby script/live_check.rb
#
# This exists because the feature can only be observed for real during a
# match, roughly twice a month. Everything that decides what to say is
# pure, so it can be replayed here instead.

require "json"
require "set"
require "time"

module ::LaligaMatchday
  PLUGIN_NAME = "discourse-laliga-matchday"
end

# Minimal ActiveSupport stand-ins used by the reporter.
class NilClass; def present?; false; end; def blank?; true; end; end
class String; def present?; !strip.empty?; end; def blank?; strip.empty?; end; end
class Object; def present?; !nil?; end; end

ROOT = File.expand_path("..", __dir__)
require File.join(ROOT, "lib/laliga_matchday/match_event")
require File.join(ROOT, "lib/laliga_matchday/live_reporter")

# The real service loads without Rails so long as nothing calls a method
# that needs it, so the date arithmetic is checked against the actual
# implementation rather than a copy of it.
require File.join(ROOT, "lib/laliga_matchday/matchday_service")

FIXTURE = JSON.parse(File.read(File.join(ROOT, "spec/fixtures/espn_live_match.json")))
SEVILLA = "243"
FAILURES = []

def check(name)
  result = yield
  if result == true
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}#{result.is_a?(String) ? " — #{result}" : ""}"
    FAILURES << name
  end
rescue => e
  puts "  ERROR #{name} — #{e.class}: #{e.message}"
  FAILURES << name
end

def match_at(phase)
  FIXTURE.fetch(phase)["events"].first
end

R = ::LaligaMatchday::LiveReporter

puts "\nFinding the match"

check("picks our match out of the day's fixtures") do
  payload = { "events" => FIXTURE["full_time"]["events"] + FIXTURE["other_match_only"]["events"] }
  found = payload["events"].find do |e|
    Array(e["competitions"]).first["competitors"].any? { |c| c.dig("team", "id") == SEVILLA }
  end
  found && found["id"] == "700001" || "got #{found && found["id"]}"
end

check("a day with no Sevilla match yields nothing") do
  FIXTURE["other_match_only"]["events"].none? do |e|
    Array(e["competitions"]).first["competitors"].any? { |c| c.dig("team", "id") == SEVILLA }
  end
end

puts "\nClassifying events"

events = R.events(match_at("second_half"))

check("reads every detail") { events.size == 7 || "got #{events.size}" }

check("a plain goal is a goal") do
  events.find { |e| e.minute == "23'" }&.kind == :goal
end

check("an own goal is not filed as a goal") do
  events.find { |e| e.minute == "55'" }&.kind == :own_goal
end

check("a scored penalty is distinguished") do
  events.find { |e| e.minute == "64'" }&.kind == :penalty_goal
end

# A second yellow arrives flagged as a red card, so the more specific
# test has to run first or every dismissal reads as a straight red.
check("a second yellow is not reported as a straight red") do
  events.find { |e| e.minute == "76'" }&.kind == :second_yellow
end

check("a yellow is a yellow") { events.find { |e| e.minute == "12'" }&.kind == :yellow }
check("a substitution is a substitution") { events.find { |e| e.minute == "70'" }&.kind == :substitution }

puts "\nRunning score"

check("the running score matches the scoreboard at full time") do
  last = R.events(match_at("full_time")).select(&:scoring?).last
  last.home_score == 2 && last.away_score == 2 ||
    "got #{last.home_score}-#{last.away_score}"
end

# The own goal is credited to Sevilla's opponent even though ESPN files
# it under the team that conceded it.
check("an own goal credits the other side") do
  own = R.events(match_at("second_half")).find { |e| e.kind == :own_goal }
  own.home_score == 1 && own.away_score == 1 || "got #{own.home_score}-#{own.away_score}"
end

check("the penalty puts the away side ahead") do
  pen = R.events(match_at("second_half")).find { |e| e.kind == :penalty_goal }
  pen.home_score == 1 && pen.away_score == 2 || "got #{pen.home_score}-#{pen.away_score}"
end

puts "\nDeduplication across polls"

allowed = R::DEFAULT_KINDS

check("the same poll twice announces nothing the second time") do
  first = R.unannounced(R.events(match_at("first_half")), [], allowed)
  keys = first.map(&:key)
  again = R.unannounced(R.events(match_at("first_half")), keys, allowed)
  again.empty? || "#{again.size} repeated"
end

check("only the new events are announced as the match moves on") do
  seen = R.unannounced(R.events(match_at("first_half")), [], allowed).map(&:key)
  later = R.unannounced(R.events(match_at("second_half")), seen, allowed)
  minutes = later.map(&:minute)
  minutes == ["55'", "64'", "74'", "76'"] || "got #{minutes.inspect}"
end

check("yellows and subs are filtered out by the default policy") do
  all = R.unannounced(R.events(match_at("second_half")), [], allowed)
  all.none? { |e| %i[yellow substitution].include?(e.kind) } || "noise leaked through"
end

check("widening the policy lets them through") do
  wide = allowed + %w[yellow substitution]
  all = R.unannounced(R.events(match_at("second_half")), [], wide)
  all.any? { |e| e.kind == :yellow } && all.any? { |e| e.kind == :substitution }
end

check("keys are stable between polls") do
  a = R.events(match_at("first_half")).map(&:key)
  b = R.events(match_at("second_half")).map(&:key)
  (a - b).empty? || "keys changed: #{(a - b).inspect}"
end

# Two bookings for the same team in the same minute must not collapse
# into one key, or only the first would ever be reported.
check("two similar events in one minute keep separate keys") do
  detail = lambda do |player|
    {
      "type" => { "text" => "Yellow Card" }, "clock" => { "displayValue" => "40'" },
      "team" => { "id" => "2922" }, "yellowCard" => true, "scoringPlay" => false,
      "athletesInvolved" => [{ "displayName" => player }],
    }
  end
  names = { "2922" => "Getafe" }
  one = ::LaligaMatchday::MatchEvent.from_detail(detail.call("A"), names)
  two = ::LaligaMatchday::MatchEvent.from_detail(detail.call("B"), names)
  one.key != two.key || "both #{one.key}"
end

puts "\nVAR reversal"

check("a struck-off goal is detected as retracted") do
  before = R.events(match_at("second_half")).map(&:key)
  after = R.events(match_at("var_reversal"))
  gone = R.retracted(after, before)
  gone.size == 1 && gone.first.include?("74'") || "got #{gone.inspect}"
end

check("a yellow that vanishes is not announced as a disallowed goal") do
  before = R.events(match_at("second_half")).map(&:key)
  trimmed = R.events(match_at("second_half")).reject { |e| e.kind == :yellow }
  R.retracted(trimmed, before).none? { |k| k.start_with?("yellow") }
end

puts "\nFinding the matchday topic"

M = ::LaligaMatchday::MatchdayService

ROUNDS = {
  "7" => { "topic_id" => 101, "first_kickoff" => "2026-09-18T19:00:00Z", "last_kickoff" => "2026-09-21T19:00:00Z" },
  "8" => { "topic_id" => 102, "first_kickoff" => "2026-09-25T19:00:00Z", "last_kickoff" => "2026-09-28T19:00:00Z" },
}.freeze

def covering(iso)
  M.covering_entry(ROUNDS, Time.parse(iso))
end

check("a Saturday match lands in its own round") do
  covering("2026-09-20T19:00:00Z")&.dig("topic_id") == 101 || covering("2026-09-20T19:00:00Z").inspect
end

check("the following round is found a week later") do
  covering("2026-09-26T19:00:00Z")&.dig("topic_id") == 102
end

# A Friday opener is posted before the round's stored first kickoff only
# by minutes, but a match that runs past midnight UTC finishes on the
# next calendar day — hence a grace day at each end.
check("a match running past midnight still matches its round") do
  covering("2026-09-22T00:30:00Z")&.dig("topic_id") == 101
end

check("the day before the round opens still matches") do
  covering("2026-09-17T20:00:00Z")&.dig("topic_id") == 101
end

check("a date in no round returns nothing") do
  covering("2026-08-01T19:00:00Z").nil?
end

# With a grace day at both ends, consecutive rounds overlap. The nearer
# kickoff has to win or a Monday match could be filed under next week.
check("overlapping rounds resolve to the nearer one") do
  covering("2026-09-22T19:00:00Z")&.dig("topic_id") == 101 ||
    "got #{covering("2026-09-22T19:00:00Z").inspect}"
end

check("a round with no end time still matches on its start") do
  one = { "9" => { "topic_id" => 103, "first_kickoff" => "2026-10-02T19:00:00Z" } }
  M.covering_entry(one, Time.parse("2026-10-02T21:00:00Z"))&.dig("topic_id") == 103
end

check("an unparseable stored time does not raise") do
  junk = { "9" => { "topic_id" => 104, "first_kickoff" => "not a date" } }
  M.covering_entry(junk, Time.parse("2026-10-02T21:00:00Z")).nil?
end

check("empty storage returns nothing") { M.covering_entry({}, Time.now).nil? }

# The title fallback is the strategy that will actually run on a site
# that was already live, so the SQL LIKE pattern has to match what the
# builder really produces.
puts "\nMatching preview topics by title"

def preview_title(competition, matchday, season)
  "#{competition} Matchday #{matchday} Preview — #{season}"
end

def like_match?(title, season)
  pattern = "%Matchday %Preview%#{season}%"
  regexp = Regexp.new("\\A" + Regexp.escape(pattern).gsub("%", ".*") + "\\z")
  !!(title =~ regexp)
end

check("the pattern matches a real preview title") do
  like_match?(preview_title("La Liga", 9, "2026/27"), "2026/27") ||
    preview_title("La Liga", 9, "2026/27")
end

check("it matches a two-digit matchday") do
  like_match?(preview_title("La Liga", 28, "2026/27"), "2026/27")
end

check("it does not match the results topic") do
  !like_match?("La Liga Matchday 9 Results — 2026/27", "2026/27")
end

check("it does not match a different season") do
  !like_match?(preview_title("La Liga", 9, "2025/26"), "2026/27")
end

check("it does not match an unrelated topic") do
  !like_match?("Matchday thoughts and previews", "2026/27")
end

# A live match thread the plugin created itself must never be mistaken
# for the preview, or coverage would chase its own tail.
check("it does not match a live match topic") do
  !like_match?("Sevilla v Real Madrid — Live — 18 Oct 2026", "2026/27")
end

puts "\nWhat gets posted"

goal = R.events(match_at("first_half")).find { |e| e.kind == :goal }
text = R.reply_for(goal, match_at("first_half"))

check("a goal reply names the scorer") { text.include?("Isaac Romero") || text }
check("a goal reply carries the new score") { text.include?("1–0") || text }
check("a goal reply names both clubs") { text.include?("Sevilla") && text.include?("Getafe") }
check("a goal reply states the minute") { text.include?("23'") || text }

check("an own goal is labelled as one") do
  og = R.events(match_at("second_half")).find { |e| e.kind == :own_goal }
  R.reply_for(og, match_at("second_half")).include?("OWN GOAL")
end

check("a penalty is labelled as one") do
  pen = R.events(match_at("second_half")).find { |e| e.kind == :penalty_goal }
  R.reply_for(pen, match_at("second_half")).include?("(pen)")
end

check("a dismissal reads as a second yellow") do
  red = R.events(match_at("second_half")).find { |e| e.kind == :second_yellow }
  R.reply_for(red, match_at("second_half")).include?("Second yellow")
end

# Written carefully: `include?("")` is true of every string, so the
# obvious version of this check passes unconditionally.
def malformed?(text)
  text.include?("nil") ||
    text.include?("· \n") ||
    text.end_with?("·") ||
    text =~ /\S  +\S/ ||
    text != text.strip
end

check("no reply contains a stray nil, dangling separator or double space") do
  bad =
    R.events(match_at("full_time"))
      .map { |e| R.reply_for(e, match_at("full_time")) }
      .select { |t| malformed?(t) }
  bad.empty? || bad.inspect
end

check("that check can actually fail") do
  samples = ["⚽ GOAL — nil", "23' Sevilla ·", "a  b", " padded "]
  samples.all? { |t| malformed?(t) } || "missed #{samples.reject { |t| malformed?(t) }.inspect}"
end

check("an event with no player named still reads cleanly") do
  bare =
    ::LaligaMatchday::MatchEvent.new(
      kind: :goal, minute: "12'", team_id: "243", team_name: "Sevilla",
      home_score: 1, away_score: 0
    )
  text = R.reply_for(bare, match_at("first_half"))
  !malformed?(text) || text.inspect
end

puts "\nThe opening post"

check("before kick off it shows the fixture, not a score claim") do
  body = R.opening_post(match_at("pre"))
  body.include?("Sevilla") && body.include?("Getafe") || body
end

check("in play it shows the clock") do
  R.opening_post(match_at("second_half")).include?("78'")
end

check("at full time it says so") do
  R.opening_post(match_at("full_time")).include?("Full time")
end

check("the opening post changes as the match does") do
  a = R.opening_post(match_at("first_half"))
  b = R.opening_post(match_at("second_half"))
  a != b || "identical, so the post would never be updated"
end

check("an unchanged poll produces an identical body") do
  R.opening_post(match_at("half_time")) == R.opening_post(match_at("half_time"))
end

puts "\nStatus reading"

check("pre, in and post are told apart") do
  {
    "pre" => "pre", "first_half" => "in", "half_time" => "in",
    "second_half" => "in", "full_time" => "post"
  }.all? { |phase, want| R.status(match_at(phase))[:state] == want }
end

check("full time is flagged complete") { R.status(match_at("full_time"))[:completed] == true }
check("half time is not flagged complete") { R.status(match_at("half_time"))[:completed] == false }

check("half time is recognisable from the detail string") do
  R.status(match_at("half_time"))[:detail] =~ /\bHT\b/ ? true : R.status(match_at("half_time"))[:detail]
end

puts
if FAILURES.empty?
  puts "All checks passed."
else
  puts "#{FAILURES.size} failed: #{FAILURES.join(", ")}"
  exit 1
end
