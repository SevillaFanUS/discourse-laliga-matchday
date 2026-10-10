# frozen_string_literal: true

require "net/http"
require "json"
require "time"

module ::LaligaMatchday
  # Fetches a day's scoreboard for a league.
  #
  # Two sources, same response shape: ESPN directly, and worldcup26.ir,
  # which mirrors ESPN into MongoDB and serves a provider-compatible
  # payload. The mirror exists as a fallback because ESPN already refuses
  # some endpoints from some servers — its roster endpoint answers 403
  # from this one — so having a second route costs one setting.
  class LiveSource
    SOURCES = {
      "espn" => "https://site.api.espn.com/apis/site/v2/sports/soccer/%<league>s/scoreboard?dates=%<date>s",
      "mirror" => "https://worldcup26.ir/get/soccer/%<league>s/scoreboard?dates=%<date>s",
    }.freeze

    attr_reader :last_error

    def initialize(source: nil, league: nil)
      @source = (source.presence || "espn").to_s
      @league = (league.presence || "esp.1").to_s
    end

    def self.names
      SOURCES.keys
    end

    # @return [Hash, nil] the raw scoreboard payload
    def scoreboard(date = Time.now.utc)
      @last_error = nil

      template = SOURCES[@source] || SOURCES["espn"]
      url = format(template, league: @league, date: date.strftime("%Y%m%d"))

      get(url)
    end

    # Pulls out the one match involving the given team, if any.
    def self.find_match(payload, team_id)
      return nil if payload.nil?

      wanted = team_id.to_s

      Array(payload["events"]).find do |event|
        competition = Array(event["competitions"]).first
        Array(competition && competition["competitors"]).any? do |side|
          (side.dig("team", "id") || side["id"]).to_s == wanted
        end
      end
    end

    private

    def get(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 8
      # Kept short on purpose: this runs twice a minute during a match,
      # and a slow source should be skipped rather than pile jobs up.
      http.read_timeout = 12

      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "discourse-laliga-matchday"

      response = http.request(request)

      return fail!("HTTP #{response.code} from #{uri.host}") unless response.is_a?(Net::HTTPSuccess)

      body = response.body.to_s
      return fail!("empty response from #{uri.host}") if body.strip.empty?

      JSON.parse(body)
    rescue JSON::ParserError => e
      fail!("unparseable response from #{uri.host}: #{e.message}")
    rescue => e
      fail!("#{e.class}: #{e.message}")
    end

    def fail!(message)
      @last_error = message
      Rails.logger.warn("[#{::LaligaMatchday::PLUGIN_NAME}] live: #{message}") if defined?(Rails)
      nil
    end
  end
end
