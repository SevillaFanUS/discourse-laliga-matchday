# discourse-laliga-matchday

Posts two automatic topics per La Liga matchday:

- **Preview** — before the round's first kickoff: every fixture with
  kickoff times in multiple timezones, your club's match highlighted, and
  the table going in.
- **Review** — once the round is done: all results, the updated table,
  and current top scorers.

Data comes from [football-data.org](https://www.football-data.org/) —
the free tier is enough (about 3 requests per run, against a 10/minute
limit).

---

## How it works

A scheduled job (`LaligaMatchdaySync`) runs hourly and asks
`MatchdayService` whether anything is due.

**Matchday boundaries are derived from the fixtures themselves**, not
from the API's `currentMatchday`. La Liga rounds sprawl Friday–Monday,
midweek rounds exist, and postponements pull individual games out of
their round — so the service groups the season's matches by `matchday`
and uses each round's actual first and last kickoff.

- **Preview** fires when a round's first kickoff falls inside the next
  `laliga_matchday_preview_hours_before` hours (default 48).
- **Review** is a **single live post per matchday**, not a one-shot
  summary. It goes up as soon as the first match of the round finishes,
  then the same post is edited in place as the rest of the results come
  in. Unplayed fixtures show their kickoff time rather than a dash, and a
  progress line reads "3 of 10 matches played".

  This design exists because La Liga rounds sprawl — matchday 1 of
  2026/27 runs 15–27 August. Waiting for every match to resolve would put
  the results post nearly two weeks late, arriving after matchdays 2 and
  3 had already been previewed. Several rounds can be live at once, so
  every eligible round is synced each run.

  Once the round is fully resolved (plus a 2-hour settle window for late
  score corrections) the post is marked *Final* and bumped once. Before
  that, edits are silent so the topic isn't pushed to the top of Latest
  every few hours.

- **Nothing is written unless something changed.** Each run fingerprints
  the rendered body and compares it to the last version; identical means
  no edit. The "updated" timestamp is deliberately excluded from that
  fingerprint, otherwise every check would look like a change.
- State is tracked in `PluginStore`, keyed by competition **and season**,
  so a new season starts clean rather than thinking matchday 1 was
  already covered last year.
- Rounds whose first kickoff is more than 21 days ago are ignored, so
  installing mid-season doesn't backfill the entire year.

Topics are posted as the Discourse system user.

## Install

```yaml
- exec:
    cd: $home/plugins
    cmd:
      - git clone https://github.com/SevillaFanUS/discourse-laliga-matchday.git
```

Then `./launcher rebuild app`.

## Configure

Admin → Settings → search `laliga_matchday`:

| Setting | Notes |
| --- | --- |
| `laliga_matchday_enabled` | Off by default. |
| `laliga_matchday_api_key` | football-data.org key — the same one the sidebar plugin uses is fine. |
| `laliga_matchday_category_id` | **Required.** Nothing posts until set. |
| `laliga_matchday_competition_code` | `PD` = La Liga. |
| `laliga_matchday_season` | Blank = auto-detect (June rollover). |
| `laliga_matchday_team_id` | `559` = Sevilla. Highlights your club. |
| `laliga_matchday_post_preview` / `_post_review` | Toggle either post type. |
| `laliga_matchday_preview_hours_before` | Default 48. |
| `laliga_matchday_timezones` | Comma-separated. First is primary (shown with full date). |
| `laliga_matchday_standings_rows` | Table length; your club is always included even if below the cut. |
| `laliga_matchday_tags` | Comma-separated tags. |

## Testing before you trust it

`MatchdayService#dry_run` renders a post body **without** posting
anything:

```bash
cd /var/discourse && ./launcher enter app
su discourse -c "RAILS_ENV=production bin/rails runner '
  puts LaligaMatchday::MatchdayService.new.dry_run(:preview, 1)
'"
```

Swap `:preview` for `:review` and `1` for any matchday number.

To force a real run immediately:

```bash
su discourse -c "RAILS_ENV=production bin/rails runner '
  Jobs::LaligaMatchdaySync.new.execute({})
'"
```

To re-post a matchday you've already covered, clear it from the state
key (note the competition/season suffix):

```bash
su discourse -c "RAILS_ENV=production bin/rails runner '
  key = \"previewed_matchdays_PD_2026\"
  puts PluginStore.get(\"discourse-laliga-matchday\", key).inspect
  PluginStore.remove(\"discourse-laliga-matchday\", key)
'"
```

## Notes and limitations

- **Provisional kickoffs.** football-data.org reports `SCHEDULED` for
  fixtures whose exact slot La Liga hasn't confirmed (typically until
  ~2 weeks out) and `TIMED` once locked. Preview posts mark the former
  with *(TBC)* and carry a short explanatory note. A preview posted 48h
  ahead will almost always have confirmed times; longer preview windows
  will show more TBCs.
- **Posts are point-in-time.** They aren't rewritten if a kickoff moves
  after posting. Keeping them live-updated is possible but is a
  meaningfully different design — see the schedule plan.
- **No match stats.** Possession, shots, xG etc. aren't on
  football-data.org's free tier. Results, standings and scorers are.

---

## Live match threads

Follows a team through a match and posts as it happens. Off by default;
enable `laliga_live_enabled`.

A topic is created about ten minutes before kick off. Its **opening post
is a running scoreline**, edited in place. **Each notable event gets its
own reply.**

```
⚽ **GOAL — Sevilla 1–0 Getafe**
23' Sevilla · Isaac Romero

⚽ **GOAL (pen) — Sevilla 1–2 Getafe**
64' Getafe · Borja Mayoral

🟥 **Second yellow — Getafe**
76' Djené

⏹️ **Full time — Sevilla 2–2 Getafe**
```

That 2-2 with a sending off produces six replies. A quiet 1-0 produces
three. Add `yellow` and `substitution` to `laliga_live_announce` and a
busy match will produce twenty-five, which is a decision worth making
after watching one round rather than before.

### Where the data comes from

Match events are read from the **scoreboard's own `details` array**, not
from a separate play-by-play endpoint. One request returns the score and
every event for every match that day, and there is no second host that
can fail independently.

Two interchangeable sources, same response shape:

| `laliga_live_source` | Notes |
| --- | --- |
| `espn` *(default)* | Direct. |
| `mirror` | worldcup26.ir, which republishes ESPN from its own cache. |

The mirror is a hedge, not an equal. It is a single-maintainer project
with no SLA — worth having configured because ESPN already refuses some
endpoints from some servers, and switching is one setting.

### Thirty seconds, on a one-minute scheduler

Discourse's scheduler has one-minute granularity. So the scheduled job
runs every minute, polls, and — only while a match is in progress —
enqueues a single follow-up thirty seconds later.

**The follow-up never enqueues another.** A self-perpetuating chain can
outlive the match if a full-time transition is ever missed, and a job
polling forever is a worse failure than a missed thirty-second slot.

Off matchday the job costs one PluginStore read and exits.

### Things that would otherwise go wrong

**Duplicate announcements.** Events have no id in the feed, so a stable
key is built from kind, minute, team and player — the player included
because two bookings in the same minute for the same side are otherwise
identical. A key is recorded *before* its reply is posted: a crash
between the two should lose a message, never repeat a goal.

**Own goals.** The feed files an own goal under the team that conceded
it. The running score credits the other side.

**Second yellows.** These arrive flagged as a red card, so the specific
test runs first or every dismissal reads as a straight red.

**Scheduled matches reporting 0–0.** Scores are only read once a match is
live.

**VAR.** A struck-off goal simply vanishes from the feed. That is
detected and a short "Goal disallowed" reply follows. The original reply
is not deleted — the thread reads as a record of what was known at the
time.

**`max_consecutive_replies`.** Discourse limits consecutive replies by
one user, default 3. The system user should be exempt as both staff and
topic owner, but a rejected post is logged explicitly rather than failing
quietly, because this is the failure that would silently truncate a 4-0
win.

### Rehearsing without posting

```bash
# compare both sources from this server
bin/rails runner plugins/discourse-laliga-matchday/script/live_probe.rb 20260920

# fetch the real feed and print what WOULD be posted, changing nothing
bin/rails runner plugins/discourse-laliga-matchday/script/live_dry_run.rb

# replay a whole match offline: no Rails, no network, no database
ruby script/live_check.rb
```

`live_check.rb` replays a full match poll by poll through the same code
that runs live — 40 checks covering classification, running score,
deduplication, VAR retraction and reply wording. It exists because the
real thing can only be observed twice a month.

