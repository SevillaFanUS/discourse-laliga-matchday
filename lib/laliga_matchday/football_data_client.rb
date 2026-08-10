# frozen_string_literal: true

require "net/http"
require "json"

module ::LaligaMatchday
  # Thin football-data.org v4 client. Every call returns the parsed JSON
  # hash, or nil on any failure — callers are expected to degrade
  # gracefully (e.g. post fixtures without a standings table) rather than
  # blow up a scheduled job over one bad response.
  class FootballDataClient
    BASE_URL = "https://api.football-data.org/v4"

    def initialize(api_key)
      @api_key = api_key
    end

    # The whole season in one request — 380 matches for La Liga. Cheaper
    # and more robust than paging per matchday, and it lets us work out
    # matchday boundaries locally instead of trusting currentMatchday,
    # which drifts around postponements.
    def season_matches(competition:, season:)
      get("/competitions/#{competition}/matches?season=#{season}")
    end

    def standings(competition:, season:)
      get("/competitions/#{competition}/standings?season=#{season}")
    end

    def scorers(competition:, season:, limit: 10)
      get("/competitions/#{competition}/scorers?season=#{season}&limit=#{limit}")
    end

    private

    def get(path)
      uri = URI("#{BASE_URL}#{path}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 20

      request = Net::HTTP::Get.new(uri)
      request["X-Auth-Token"] = @api_key

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn(
          "[#{::LaligaMatchday::PLUGIN_NAME}] HTTP #{response.code} for #{path}: #{response.body.to_s[0, 300]}",
        )
        return nil
      end

      JSON.parse(response.body)
    rescue => e
      Rails.logger.warn("[#{::LaligaMatchday::PLUGIN_NAME}] request failed for #{path}: #{e.message}")
      nil
    end
  end
end
