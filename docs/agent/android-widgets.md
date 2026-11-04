# Android home-screen widgets

Native Android home-screen widgets (Jetpack Glance, API 24+). Flutter stays the
only owner of app data: Dart computes a small JSON **snapshot** from the existing
providers / statistics functions and pushes it to native; the Glance widgets only
render that snapshot (plus one live native read: AnkiDroid due counts).

## Architecture

```
Drift / srs.db / prefs ──► WidgetSnapshotSource.collect()   (fushi/lib/src/platform/widget_snapshot_source.dart)
                              │  pure: buildWidgetSnapshot()   (widget_snapshot.dart, unit-tested)
                              ▼
               MethodChannel app.fushi.reader/widgets  updateSnapshot(json)
                              ▼
   WidgetStore (SharedPreferences "fushi_widget_snapshot")    (android/.../widgets/WidgetSnapshot.kt)
                              ▼
   Glance widgets render; taps = fushi://widget/... deep links ──► MainActivity ──► Dart WidgetLink
```

- No second database. The snapshot is a cache of display-ready values; deleting
  it only makes widgets show "Open Fushi to set up" until the next publish.
- Publishing triggers: app init, Drift `watchDashboardDataChanges()` (debounced
  3 s), `srsRevisionProvider`, app paused / resumed, locale / module / provider /
  goal / privacy setting changes. Signature de-duplication: identical JSON is not
  re-sent; the signature ignores `generatedAt`, but an unchanged snapshot is still
  re-sent after 10 minutes so the native "updated N ago" does not go stale.
- Widgets survive process death, reboot and app updates because the snapshot is
  persisted natively and Glance re-renders from it. `updatePeriodMillis` (30 min)
  re-renders so day rollover and AnkiDroid counts stay current without Flutter.
- When the snapshot's `day` is not today (device day rollover without opening the
  app), "today" values are shown as zero / "open Fushi to refresh" instead of
  yesterday's numbers. Fushi SRS due counts carry `generatedAt` so the widget can
  say "updated 3 h ago".

## SRS provider rule (no new setting)

The provider follows the existing **card destination** setting
(`AppModel.srsMiningTarget`, pref `srs_mining_target`, Settings → Card creation)
plus the SRS module toggle (`ModuleId.srs`):

| srs module | srsMiningTarget | widget provider |
|---|---|---|
| on  | `srs`  | `fushi`: counts from `srsDeckListProvider` + `loadSrsStats` |
| any | `anki` | `anki`: counts read natively from AnkiDroid's provider |
| off | `srs`  | `none`: setup state, tap opens Card creation settings |

The two providers are never mixed; the widget always prints the provider label.
Switching the setting republishes the snapshot and every widget re-renders.

## Snapshot JSON (v2)

Keys are the contract between `widget_snapshot.dart` and `WidgetSnapshot.kt`.
Every new field is optional for the parser (missing → hidden / empty state).
All user-visible strings are already localized and formatted in Dart.

```jsonc
{
  "v": 2,
  "day": "2026-11-02",            // stat day key (respects stats_day_reset_hour)
  "generatedAt": 1793600000000,    // epoch ms
  "profile": { "name": "Default", "multi": false },   // multi = more than 1 profile
  "privacy": { "hideTitles": false, "hideDefinitions": false, "hideProfile": false }, // app defaults
  "labels": { "<key>": "<localized text>" },
  "modules": { "books": true, "manga": true, "video": true, "lookup": true,
               "srs": true, "music": true, "games": true },

  "continue": { /* media */ } | null,
  "shelf": [ /* media, max 4 */ ],
  // media = { "kind": "book|manga|video|game", "id", "title", "subtitle", "progress": 0..1,
  //           "cover": "<abs path>|''", "position": "45%"|"", "lastActive": "2 h ago"|"",
  //           "link": "fushi://widget/..." }   // Dart-built tap target, see "One continue source"

  "today": {
    "time": "2h 15m", "chars": "12.3k", "goal": 0.4,  // legacy: chars goal fraction
    "streak": 12,
    "totalMs": 8100000,
    "categories": [                 // fixed order; ms may be 0
      { "id": "reading",   "label": "Reading",   "ms": 3900000, "time": "1h 05m", "link": "fushi://widget/tab/books" },
      { "id": "listening", "label": "Listening", "ms": 0,       "time": "0m",     "link": "fushi://widget/tab/music" },
      { "id": "watching",  "label": "Watching",  "ms": 1500000, "time": "25m",    "link": "fushi://widget/tab/video" },
      { "id": "games",     "label": "Games",     "ms": 0,       "time": "0m",     "link": "fushi://widget/tab/games" }
    ],
    "goalMs": 10800000, "goalTime": "3h", "goalFrac": 0.75   // goalMs 0 = no time goal
  },

  "goals": [                        // only goals the user configured (target > 0)
    { "id": "total|reading|listening|watching|reviews|mined|chars",
      "label": "Immersion", "value": "45m", "target": "3h", "frac": 0.25, "done": false }
  ],

  "week": {
    "minutes": [7 ints, oldest→today], "days": [7 narrow weekday labels],
    "time": "9h 40m", "chars": "80k",
    "prevTime": "8h 10m", "deltaPct": 18,            // deltaPct null when no previous data
    "reviews": 340,                                  // Fushi SRS only; null otherwise
    "goalDays": 4                                    // days in the 7 that met the time goal; null if no goal
  },

  "month": {                        // last 35 stat days, oldest→today (5 rows × 7)
    "minutes": [35 ints], "reviews": [35 ints] | null,
    "time": "31h", "activeDays": 22, "firstWeekday": 1   // ISO weekday of minutes[0]
  },

  "streak": {
    "current": 12, "longest": 30,                   // study days (any immersion)
    "srsCurrent": 5, "srsLongest": 41,              // Fushi SRS only; null otherwise
    "week": [7 bools, oldest→today]                  // active study days
  },

  "srs": {
    "provider": "fushi|anki|none",
    "label": "Fushi SRS",
    "enabled": true, "due": 128,                     // legacy fields (fushi only)
    "new": 20, "learn": 18, "review": 90,            // fushi only
    "reviewedToday": 52,                             // fushi only
    "dueTomorrow": 75,                               // fushi only
    "timeline": [ { "at": 1793603600000, "due": 131 } ],  // fushi only: future change points only
    "ankiPackage": "com.ichi2.anki"                  // anki only: package to query / launch
  },

  "heatmap": {                      // last 112 stat days (16 weeks), oldest→today
    "levels": [112 ints 0..4],      // widgetHeatLevel: 0 none, 1 <15m (or untimed activity),
                                    // 2 <30m, 3 <60m, 4 ≥60m — fixed thresholds
    "firstWeekday": 6, "time": "64h", "activeDays": 90
  },

  "rollover": {                     // null when no future boundary is known
    "at": 1793640000000,            // next stat-day boundary (honours stats_day_reset_hour)
    "day": "2026-11-03",
    "today": {...}, "goals": [...], "week": {...}, "month": {...},
    "streak": {...}, "heatmap": {...}   // same shapes as top level, computed for "day"
  },

  "vocab": [                        // up to 12, newest first, deterministic
    { "term": "...", "reading": "", "definition": "", "sentence": "", "source": "Book title",
      "origin": "mined|favorite" }
  ],

  "downloads": {                    // Downloads widget
    "count": 4,                     // unfinished tasks: running, queued, paused, failed
    "running": 2,                   // active + queued; the app keeps pushing while > 0
    "percent": 63,                  // mean progress of non-failed tasks that report one; null if none
    "speed": "2.4 MB/s",            // summed live speed of active tasks, "" if unknown
    "tasks": [                      // top 3: active, queued, failed, paused (newest first within a rank)
      { "id": "...", "title": "...", "state": "active|queued|paused|failed",
        "percent": 41 | null, "speed": "1.2 MB/s" | "" }
    ]
  },

  "onDeck": {                       // On deck widget (media-server items)
    "state": "none|off|ok",         // none = no server configured, off = servers exist but their
                                    // items are not mixed into Home > Continue (opt-in), ok
    "items": [                      // ok only; up to 4, newest first
      { "kind": "video|audiobook", "title": "Series or title", "subtitle": "S1E2 Episode name",
        "server": "Jellyfin", "progress": 0..1, "position": "45%", "cover": "<abs path>|''",
        "lastActive": "2 h ago", "link": "fushi://widget/server?source=...&server=...&item=..." }
    ]
  }
}
```

`media.remaining` (every `continue` / `shelf` entry) is the pre-formatted "time to finish"
("≈2h 10m left", `widget_label_time_left`) or `""` when it cannot be estimated honestly.

### Time-dependent fields (resolved natively, never recomputed)

- `srs.timeline` (`buildWidgetSrsDueTimeline`): learning / relearning cards ripen at their exact
  `dueAt` (merged per minute, per hour past 40 points); at the SRS day boundary (store's
  `dayIndexOf`, binary-searched to the minute) the reviews due on the next SRS day are added.
  Horizon 24 h. Only points after `generatedAt` whose count differs are sent ("now" is
  `srs.due`), so the publisher's signature dedup still works. Native: the count shown at time
  *t* is the last point with `at <= t`, else `srs.due`.
- `rollover`: the day-dependent blocks (`today`, `goals`, `week`, `month`, `streak`, `heatmap`)
  re-run by the same Dart builder for the next stat day — today zeroed, the streak kept when
  today had activity and broken otherwise, arrays shifted by one. Native swaps them in once
  `now >= rollover.at` (`day` too, so the word of the day rotates).
- Apple: `FushiSnapshotProvider` emits one timeline entry for now, every `srs.timeline` point
  and `rollover.at` inside 24 h, each `FushiWidgetSnapshot.resolved(at:)`; policy
  `.after(24 h)`. Android: `WidgetStore.load` applies `resolveRollover` and `srsDueAt` on every
  load (Glance re-renders on its update period / any new snapshot). Android has no 16-week
  view; the `heatmap` field is still the same JSON.

### One continue source

`shelf` / `continue` is the only "continue" source for every widget (Android and Apple), mixed
like Home > Continue by `recentAt`:

| item | where it comes from | `link` |
|---|---|---|
| book / manga / video | local library (`isDashboardContinueBook`, `listForShelf`) | `continue?kind=&id=` |
| game | `GalgameRepository`, `lastPlayedMs > 0` | `continue?kind=game&id=` → games tab only (no silent launch, BUG-1111) |
| interconnect remote | `RemoteContinueFeed` (published by the dashboard after its fetch; no widget request) | `tab/books` / `tab/video` (same as the Home remote card) |
| media server / ABS | the On deck items (`ServerContinueFeed`, same opt-in gates and covers) | `server?source=&server=&item=` |

## `labels` keys (stable contract)

Defined in `kWidgetLabelKeys` (`widget_snapshot.dart`), filled by `buildWidgetLabels()`
(`widget_snapshot_labels.dart`); a unit test pins both. The native side must tolerate
missing keys (own English fallback).

- v1: `kind_book kind_manga kind_video resume today streak srsDue srsOff review srsDone recent weekly books manga video lookup openToSetUp`
- dashboard: `dashboardTitle reading listening watching games goal ofGoal longest vsLastWeek thisMonth activeDays`
- review: `providerFushi providerAnki srsNew srsLearn reviewedToday dueTomorrow reviewNow openAnki allCaughtUp srsSetup ankiPermission`
- vocabulary / goals / shortcuts: `vocabTitle nextWord lookUp noVocab goalsTitle noGoals vocab stats settings`
- time templates: `updatedAgo agoNow agoMinutes agoHours agoDays`
- extras: `openToRefresh zeroTime streakSrs weekReviews weekGoalDays recentDays`
- now playing: `nowPlaying nothingPlaying play pause previous next skipBack skipForward kind_audiobook kind_music` (`skipBack` / `skipForward` are `{n}` templates)
- downloads / on deck: `downloadsTitle noDownloads downloadQueued downloadPaused downloadFailed
  downloadsActive({n}) onDeckTitle onDeckNoServers onDeckEmpty onDeckOff kind_audiobook`

Templates carry placeholders for the native side to fill at display time:
`updatedAgo` = "Updated {age}", `agoMinutes|agoHours|agoDays`
= "{n} min ago" etc., `agoNow` = "Just now". Note there is no separate "Review" count
label: Fushi shows New / Learning (`srsNew`, `srsLearn`) and Due (`srsDue`).
`today.categories[].label` and `goals[].label` are pre-localized in the JSON itself.

Notes on the numbers:

- `week` / `deltaPct` use the **rolling** last 7 stat days vs the 7 days before them
  (not the Monday-based week of the stats page), `deltaPct` is `null` when the previous
  window has no time.
- `streak.*` counts study days over reading (all book formats), listening (music),
  watching and games; SRS reviews do not count as immersion. `srsCurrent/srsLongest` and
  the `reviews` series come from `loadSrsStats` and use the SRS day boundary (default
  4 am), aligned to "SRS today minus i days".
- `srs` for `anki` / `none` omits `new learn review reviewedToday dueTomorrow`
  entirely (and `due` is 0, `enabled` false); only `ankiPackage` is present for `anki`
  (`com.ichi2.anki`, native resolves/launches it). The reviews goal is omitted unless
  the provider is `fushi`.
- `goals[]` contains only configured goals (>0) in this order: total, reading,
  listening, watching, reviews, mined, chars. Mined-today comes from
  `mining_statistics` (same as the stats pages).
- `vocab`: newest 12 across mined sentences and favorite words, one entry per
  (term, reading); definitions/sentences are plain text (markup stripped, definition
  max 200 code points). Privacy flags only travel in `privacy`; the content is always
  present and the native side hides it.

## Deep links (`fushi://widget/...`)

Handled by `WidgetLink` (`widget_links.dart`), cold-start safe through `WidgetLinkQueue`.

| link | destination |
|---|---|
| `continue?kind=&id=` | opens and resumes that book / manga / video |
| `srs` | Fushi SRS review (first deck with work), or SRS tab |
| `stats` | Statistics center |
| `open` | app home |
| `tab/<books, manga, video, music, games, dictionaries, srs>` | that home tab (audiobooks live under books) |
| `lookup?word=` | dictionary lookup for the word |
| `settings/cards` | Settings → Card creation (SRS provider) |
| `settings/widgets` | Settings → Home-screen widgets |
| `vocab` | collections (favorite words / mined sentences) page |
| `music/now` | music player page (Now playing widget; audiobooks use `continue?kind=book`) |
| `downloads` | download center (Browse tab > Downloads > Tasks); ignored when the Browse module is off |
| `server?source=<mediaServer\|audiobookshelf>&server=<id>&item=<id>` | the same server item Home > Continue shows, opened with that card's own `open` action; lands on Home first so the dashboard feed is loaded |

The Anki "Open AnkiDroid" action is handled natively (launch intent for
`srs.ankiPackage`); Flutter is not involved.

## Per-widget configuration

Each placed widget has its own Glance state (keyed by appWidgetId), edited by
`WidgetConfigActivity` (shown when the widget is added and from "Reconfigure" on
Android 12+):

- Theme: follow system / light / dark.
- Privacy: follow app default / show / hide (titles, definitions).
- Vocabulary source (Vocabulary widget): all / mined / favorites.

Priority rule: **per-widget choice > app default (Settings → Home-screen widgets)
> built-in default (show everything)**. The SRS provider is never per-widget: it
always follows the card destination setting.

## Now playing

Widget `NowPlayingWidget` / `NowPlayingReceiver` (`NowPlayingWidget.kt`): cover, title, artist (music) or
author (audiobook), progress with elapsed / remaining, and transport buttons. Sizes: 2x1 (controls
only), 4x1 (cover + text + controls), 4x2 (header, progress bar, three buttons). Per-widget theme and
privacy apply; "hide titles" replaces the title with the kind label (`kind_music` / `kind_audiobook`)
and drops artist / author and cover.

### Playback stacks (investigated)

Music (`MusicSession` + `MusicPlayerEngine`, mpv) and audiobooks (`AudiobookSession` +
`AudiobookPlayerController`, just_audio) are different engines but share **one** audio_service
handler (`FushiAudioHandler`, built by `AudioController`) and therefore one Android `MediaSession` owned
by `com.ryanheise.audioservice.AudioService` (manifest service + `MediaButtonReceiver`).
`AudioController.sessionOwner` says which of the two currently owns it. The handler's
play / pause / skipToNext / skipToPrevious are routed to the owner.

### JSON (`nowPlaying`, null when nothing was played)

```jsonc
"nowPlaying": {
  "kind": "music|audiobook", "title": "...", "subtitle": "artist or author",
  "cover": "<abs local path or ''>",
  "positionMs": 30000, "durationMs": 200000,   // clamped 0..duration
  "playing": true, "updatedAt": 1793600000000,  // sample time of positionMs
  "link": "fushi://widget/music/now",           // audiobook: fushi://widget/continue?kind=book&id=...
  "canSkipTrack": true,                         // music: queue has >1 item; audiobook: always true
  "skipSeconds": 0                              // audiobook back / forward step: 0 = sentence, else seconds
}
```

- Source (`WidgetSnapshotSource._livePlayback`): playing music > playing audiobook > paused music >
  paused audiobook > last played song from music history (`playing=false`).
- Publishing: the full snapshot still goes through the 3 s debounce, but `MusicSession` /
  `AudiobookSession` listeners call `_onPlaybackChanged`, which on a track, play / pause or
  can-skip change **immediately** republishes the last full snapshot with a fresh `nowPlaying`
  (no debounce). Position ticks never publish. The de-dup signature
  (`widgetSnapshotSignature`) ignores `nowPlaying.positionMs` and `updatedAt`.
- Progress: native renders `positionMs + (now - updatedAt)` when playing, clamped to the duration.
  Glance only re-renders on updates, so the bar is correct at each render but does not tick on its
  own. A "playing" snapshot with no live session and older than 15 s is drawn as paused.
- Covers: local files are used as is (native decodes down-sampled, 256 px). http(s) covers
  (media-server library, online sources) are downloaded once to
  `<cache>/widget_now_playing/<sha1(url)>.img` (5 s connect, 4 MB cap, at most 8 files kept).

### Controls

Buttons run natively with no Flutter round trip: `NowPlayingControl` takes the session token from
`AudioService.instance` (package-private static, read by reflection; the class is kept in
`proguard-rules.pro`), builds a platform `MediaController` and calls `transportControls`
(`play` / `pause` / `skipToNext` / `skipToPrevious`). audio_service routes these to
`FushiAudioHandler`, which feeds the same streams the notification and headset buttons use.
Play vs pause is chosen from the **live** playback state, not the (possibly stale) snapshot.

Audiobook back / forward are `skipToPrevious` / `skipToNext`: the audiobook session already maps
them to the reader's skip interval (`skip_action_seconds`: 0 = previous / next sentence, else
5 / 10 / 15 / 30 s), so the widget labels follow that setting (`-30` / `+30` chips, or
previous / next icons for sentence mode). `FAST_FORWARD` / `REWIND` are not used: the handler maps
them to a hard-coded 5 s that only music handles.

`ACTION_MEDIA_BUTTON` to `MediaButtonReceiver` was rejected: when the service is not running it
starts audio_service as a foreground service from the background, and a session whose Dart handler
is not attached yet drops the key; PLAY_PAUSE is also a blind toggle.

### Cold start / no live session

The control path is chosen **at render time** (`NowPlayingControl.isAvailable`): the service
instance exists in this process and has published a playback state. If not (process died, playback
stopped, "show media notification" off for music), every button is a plain deep link to the player
(`link`) instead, so a tap opens Fushi and never tries to start the foreground service. If the
session disappears between render and tap, `NowPlayingActionCallback` falls back to starting
`MainActivity` with the same link (may be blocked by background-start limits; then nothing happens).
The widget is re-rendered on the next publish, which Dart sends when a session starts / stops.

### Limitations

- Progress does not tick between updates (see above); seeking does not publish.
- Music controls need the media notification setting on (music only publishes its playback state
  to audio_service when it is on); with it off the buttons just open the app.
- Idle state shows the last played song, not the last audiobook (audiobooks have the Continue widget).
- Remote (media-server) audiobook / track covers need the one-off download to have succeeded.
## Time to finish, Downloads, On deck

Pure logic and tests: `widget_progress.dart`, `test/platform/widget_snapshot_test.dart`.

**Time to finish** (`media.remaining`, shown on Continue and on the large Shelf):

- Videos: `duration - position` of the single file (`VideoFileSpecs.durationMs`, `lastPositionMs`).
  Playlists (several episodes in one row) and unprobed / streamed files have no duration: omitted.
- Books: remaining characters / reading speed. Total length and position are in characters only when
  `MediaItem.sourceMetadata != null` (set exactly when the chapter character counts are known); PDF,
  manga, online manga and old books without chapter sizes are omitted, never guessed. Speed is
  `chars / ms` from the book's own `loadStatFacts` daily rows over the last 30 stat days; if that has
  under 5 min or 300 chars it falls back to the user's overall non-manga book speed over the same
  window; below the same thresholds, or above 0.1 chars/ms (skimming), there is no estimate.
  Minimum shown: "1m".
- Audiobooks are epub-based books, so they use the book path (character progress), not playback time.

**Downloads** (`DownloadsWidget`, tap = `downloads` link):

- Sources: durable video / torrent jobs (`getVideoDownloadJobs` + `loadTaskSnapshots` for live progress
  and speed of the active ones) and the direct-link queue (`discoveryDownloadQueue`). Not included:
  manga catalog downloads, interconnect remote-host tasks, transcription tasks (their sources are
  widget-only providers). Failed tasks older than 3 days are not listed. Seeding / finished is not
  listed. The block is empty when the Browse module is off or the platform has no download center.
- Publishing: signals are `watchVideoDownloadJobs()` and the queue's listener. A tick only rebuilds
  the `downloads` block of the last full snapshot (no stats / SRS / vocab re-collection) and runs at
  most once per 5 s (`widgetDownloadsPublishDelay`). The tick re-arms itself only while a task is
  active or queued: no timer exists while idle. When the process stops pushing (killed), the widget
  detects a snapshot older than 90 s while tasks are running and shows "Updated <age>" instead of
  the speed.

**On deck** (`OnDeckWidget`, item tap = the item's `link`):

- Data is the dashboard's own `ServerContinueFeed` cache (Jellyfin / Emby / Plex Resume + NextUp and
  Audiobookshelf in-progress) behind the same opt-in gates (`serverContinueGates`, shared with the
  dashboard): the widget issues **no** server request. Consequence: items appear after Home has
  loaded the feed once in the process (the feed's `updates` stream triggers the republish) and the
  last published list stays on the widget until then. The feed does not cover Kavita.
- States: `none` ("No media servers"), `off` ("Server items are off..."), `ok` with no items
  ("Nothing in progress").
- Covers: files under `<appSupport>/widget_covers/` (`WidgetCoverCache`): fetched through the item's
  authenticated `coverFetcher` or the shared image cache, downscaled to 512 px (PNG), reused when the
  file exists, pruned to the current items on every publish, time-boxed to 5 s per publish (a slow
  server only costs the cover: glyph fallback, finished files are picked up by the next publish).
- Privacy (`hideTitles`, per-widget override like Continue / Shelf) hides titles, covers, subtitles
  and server names; the kind label stands in.

## Known limitations

- Widgets show the **active profile** only; Fushi has no target-language setting
  and vocabulary tables carry no language / profile column, so per-widget
  profile / language selection is not offered.
- Audiobook listening time is stored as book time (`format=epub`), so it is
  counted under Reading; Listening = music (when "listening counts as study").
- Downloads / On deck: see the section above for what is and is not covered. The Downloads speed
  is the torrent backend's live rate; direct-link downloads report progress but no speed.
- Fushi SRS due counts are as of the last publish (shown with an "updated" age).
  AnkiDroid counts are live but need AnkiDroid's database permission; AnkiDroid's
  API exposes no "reviewed today", so the Anki variant shows due counts only.

## Native side notes (Kotlin, `fushi/android/.../widgets/`)

- `ProgressWidgets.kt`: Downloads and On deck (receivers `DownloadsReceiver`, `OnDeckReceiver`,
  registry indices 9 and 10).
- Files: `WidgetCommon.kt` (theme, per-instance prefs, stale rule, rings / heatmap helpers),
  `FushiWidgets.kt` (Continue, Shelf), `WidgetsToday.kt` (Immersion = `TodayWidget`, Goals,
  Streak, Week), `SrsWidget.kt` (+ live AnkiDroid read), `VocabWidget.kt`,
  `ShortcutsWidget.kt`, `WidgetConfigActivity.kt`. Receivers: Continue, Today, Srs, Shelf,
  Week, Shortcuts, Goals, Streak, Vocab, NowPlaying (`NowPlayingWidget.kt`).
- Stale rule (`isFresh`): `snapshot.day` equals the device local date, or equals yesterday while it
  is before 06:00 and `generatedAt` is under 12 h old (tolerates the Dart day-reset hour).
  Otherwise today-values render as zero plus "Open Fushi to refresh".
- AnkiDroid: `content://<authority>/decks` (`FlashCardsContract.Deck.CONTENT_ALL_URI` rebased
  to the installed package's authority), column `deck_count` (`Deck.DECK_COUNTS`, JSON
  `[learn, review, new]`), summed over decks whose name has no `::`. Needs the package's
  `<package>.permission.READ_WRITE_DATABASE`. Runs on `Dispatchers.IO`.
- Per-instance Glance preference keys: `theme` (system|light|dark), `privacy`
  (follow|show|hide), `vocab_source` (all|mined|favorite), `vocab_offset` (Int),
  `vocab_offset_day` (yyyy-MM-dd; the offset only counts on the day it was set).
- `month.minutes` is drawn row-major as 5 x 7 (oldest first); `month.firstWeekday` is ignored.
- Native reads only keys from `kWidgetLabelKeys` (checked when the label sets were reconciled);
  each read has an English fallback. The AnkiDroid "not installed / unavailable" states, the
  config screen and the picker names are Android string resources (English only); everything
  else on the widgets follows the app language.
- Empty states (`noVocab`, `noGoals`) call `SetupHint(null, message)` so the specific message is
  shown; `SetupHint(snapshot, ...)` shows the generic `openToSetUp`.
- Glance caps a Row / Column at 10 children (extra children are silently dropped with a log
  line): grids use padded wrapper boxes instead of Spacer siblings, long columns nest groups.
- Per-widget config is optional on add (`configuration_optional`, Android 12+): widgets work
  with defaults; long-press → widget settings opens `WidgetConfigActivity`. Below Android 12
  the config screen opens when the widget is added.
- After `am force-stop` Android cancels the widgets' PendingIntents until they re-render (next
  update / app launch); the first tap after a force-stop can do nothing. Normal process death
  is unaffected (verified on the emulator).
- Deep links are sent as explicit intents to `MainActivity` (no manifest intent-filter needed for
  `fushi://widget/...`).

## Apple (WidgetKit)

iOS / macOS widgets render **the same snapshot** — there is no second schema,
deep-link grammar or label set:

- Dart: `WidgetSnapshotPublisher.platformSupported` is Android **or** iOS / macOS
  (`widgetSnapshotPlatformSupported()`); same `WidgetSnapshotSource`, same
  `updateSnapshot(json)` call on `app.fushi.reader/widgets`.
- Native (main app process, `fushi/apple/HomeWidgets/FushiHomeWidgets.swift`,
  `FushiWidgetSnapshotSink`): every `cover` that is a local file is downscaled to a
  512 px JPEG under `<App Group>/home_widgets/covers/` and rewritten to that
  relative path (the extension cannot read the app sandbox); remote / missing
  covers become `""`. The JSON is written atomically to
  `home_widgets/snapshot.json`, unused covers are pruned, timelines reloaded.
- Extension (`Shared/FushiWidgetSnapshot.swift`): lenient decoder of the fields
  it renders (v must equal `kWidgetSnapshotVersion`). Labels come from
  `labels` (`kWidgetLabelKeys`, including the Apple-only `continueEmpty`,
  `streakDays`, `lookupHint`, `lookupCamera`, `lookupClipboard`). Taps use
  `fushi://widget/...` (`FushiLinks`), plus `fushi://shortcut/lookup`.
- `WidgetLink` has two Apple-driven actions: `camera_lookup` and
  `clipboard_lookup` (dictionary module gated).
- Guard: `test/platform/home_widgets/apple_widget_contract_test.dart` reads the
  Swift sources and checks decoded keys / labels / hard-coded links against Dart,
  that `rollover` carries the same block shapes Swift swaps in, and that both
  native sides resolve `srs.timeline` / `rollover` / `link` at render time.
- Views: reviews due (count follows `srs.timeline`), streak, continue (shelf,
  incl. games / remote / server items), word of the day (rotates with `day`),
  16-week heatmap (`heatmap`; old snapshots fall back to the 35-day `month`),
  now playing, look up.
- Live Activities (iOS) / the macOS menu-bar player are separate from the
  snapshot: `lib/src/platform/home_widgets/` (`LiveActivityController`, serial
  sync per activity kind) over `app.fushi.reader/home_widgets`.
