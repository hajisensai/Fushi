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
  // media = { "kind": "book|manga|video", "id", "title", "subtitle", "progress": 0..1,
  //           "cover": "<abs path>|''", "position": "45%"|"", "lastActive": "2 h ago"|"" }

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
    "ankiPackage": "com.ichi2.anki"                  // anki only: package to query / launch
  },

  "vocab": [                        // up to 12, newest first, deterministic
    { "term": "...", "reading": "", "definition": "", "sentence": "", "source": "Book title",
      "origin": "mined|favorite" }
  ]
}
```

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

## Known limitations

- Widgets show the **active profile** only; Fushi has no target-language setting
  and vocabulary tables carry no language / profile column, so per-widget
  profile / language selection is not offered.
- Audiobook listening time is stored as book time (`format=epub`), so it is
  counted under Reading; Listening = music (when "listening counts as study").
- Fushi SRS due counts are as of the last publish (shown with an "updated" age).
  AnkiDroid counts are live but need AnkiDroid's database permission; AnkiDroid's
  API exposes no "reviewed today", so the Anki variant shows due counts only.

## Native side notes (Kotlin, `fushi/android/.../widgets/`)

- Files: `WidgetCommon.kt` (theme, per-instance prefs, stale rule, rings / heatmap helpers),
  `FushiWidgets.kt` (Continue, Shelf), `WidgetsToday.kt` (Immersion = `TodayWidget`, Goals,
  Streak, Week), `SrsWidget.kt` (+ live AnkiDroid read), `VocabWidget.kt`,
  `ShortcutsWidget.kt`, `WidgetConfigActivity.kt`. Receivers: Continue, Today, Srs, Shelf,
  Week, Shortcuts, Goals, Streak, Vocab.
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
