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
