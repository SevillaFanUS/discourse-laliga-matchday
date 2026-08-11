# frozen_string_literal: true

module ::LaligaMatchday
  # Renders the cached schedule as an iCalendar feed so members can
  # subscribe in Google/Apple Calendar and have fixtures update
  # themselves as La Liga confirms and moves kickoffs.
  #
  # Written by hand rather than pulled in as a dependency — iCalendar is
  # a simple line-based format and the whole feed is a few dozen lines of
  # string building.
  class IcsBuilder
    # RFC 5545 requires CRLF line endings, and lines longer than 75
    # octets must be folded. Calendar clients are notoriously strict
    # about both.
    CRLF = "\r\n"
    MAX_LINE_OCTETS = 73

    DEFAULT_DURATION_MINUTES = 115

    def initialize(data, base_url:, calendar_name: "La Liga")
      @data = data || {}
      @base_url = base_url.to_s.chomp("/")
      @calendar_name = calendar_name
    end

    def render
      lines = []
      lines << "BEGIN:VCALENDAR"
      lines << "VERSION:2.0"
      lines << "PRODID:-//monchismen//discourse-laliga-matchday//EN"
      lines << "CALSCALE:GREGORIAN"
      lines << "METHOD:PUBLISH"
      lines << "X-WR-CALNAME:#{escape_text(calendar_title)}"
      lines << "X-WR-TIMEZONE:UTC"

      each_match { |match| lines.concat(event_lines(match)) }

      lines << "END:VCALENDAR"

      lines.flat_map { |line| fold(line) }.join(CRLF) + CRLF
    end

    private

    def calendar_title
      label = @data["season_label"] || @data[:season_label]
      label.present? ? "#{@calendar_name} #{label}" : @calendar_name
    end

    def each_match
      matchdays = @data["matchdays"] || @data[:matchdays] || []
      matchdays.each do |round|
        matches = round["matches"] || round[:matches] || []
        matches.each { |m| yield(m, round) }
      end
    end

    def event_lines(match)
      start_at = parse_time(fetch(match, :utc_date))
      return [] if start_at.nil?

      home = fetch(fetch(match, :home) || {}, :name) || "TBD"
      away = fetch(fetch(match, :away) || {}, :name) || "TBD"
      uid = "laliga-#{fetch(match, :id) || "#{home}-#{away}-#{start_at.to_i}"}@monchismen"

      lines = []
      lines << "BEGIN:VEVENT"
      lines << "UID:#{uid}"
      lines << "DTSTAMP:#{format_time(Time.zone.now)}"
      lines << "DTSTART:#{format_time(start_at)}"
      lines << "DTEND:#{format_time(start_at + (DEFAULT_DURATION_MINUTES * 60))}"
      lines << "SUMMARY:#{escape_text(summary(match, home, away))}"

      description = description_for(match)
      lines << "DESCRIPTION:#{escape_text(description)}" if description.present?

      topic_url = topic_url_for(match)
      lines << "URL:#{topic_url}" if topic_url.present?

      # Unconfirmed kickoffs are marked TENTATIVE so calendar clients can
      # show them differently — they're real times, but La Liga may move
      # them.
      lines << "STATUS:#{fetch(match, :provisional) ? "TENTATIVE" : "CONFIRMED"}"
      lines << "END:VEVENT"
      lines
    end

    def summary(match, home, away)
      if fetch(match, :played)
        score = fetch(match, :score) || {}
        h = fetch(score, :home)
        a = fetch(score, :away)
        return "#{home} #{h}-#{a} #{away}" unless h.nil? || a.nil?
      end

      "#{home} v #{away}"
    end

    def description_for(match)
      parts = []
      parts << "Kickoff time is provisional and may change." if fetch(match, :provisional)
      topic_url = topic_url_for(match)
      parts << "Match thread: #{topic_url}" if topic_url.present?
      parts.join(" ")
    end

    def topic_url_for(match)
      topic_id = fetch(match, :topic_id)
      return nil if topic_id.blank? || @base_url.blank?

      "#{@base_url}/t/#{topic_id}"
    end

    # Payloads round-trip through JSON in PluginStore, so keys may be
    # symbols (fresh build) or strings (from cache).
    def fetch(hash, key)
      return nil unless hash.is_a?(Hash)

      hash[key] || hash[key.to_s]
    end

    def parse_time(value)
      return nil if value.blank?

      Time.parse(value.to_s).utc
    rescue ArgumentError, TypeError
      nil
    end

    def format_time(time)
      time.utc.strftime("%Y%m%dT%H%M%SZ")
    end

    def escape_text(value)
      value.to_s.gsub("\\", "\\\\\\\\").gsub(",", "\\,").gsub(";", "\\;").gsub(/\r?\n/, "\\n")
    end

    # Fold long lines: continuation lines begin with a single space.
    def fold(line)
      return [line] if line.bytesize <= MAX_LINE_OCTETS

      chunks = []
      remaining = line.dup
      first = true

      until remaining.empty?
        limit = first ? MAX_LINE_OCTETS : MAX_LINE_OCTETS - 1
        chunk = +""
        chunk << remaining.slice!(0) while !remaining.empty? && (chunk.bytesize + remaining[0].bytesize) <= limit
        chunks << (first ? chunk : " #{chunk}")
        first = false
      end

      chunks
    end
  end
end
