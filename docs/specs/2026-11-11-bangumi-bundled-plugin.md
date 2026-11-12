# Bangumi as the bundled tracking plugin

Status: steps 1 to 6 done; step 6 routes by platform instead of deleting (§5, §7). Not run against the real Bangumi API yet. Owner decision 2026-11-10 / 11: Bangumi
becomes a tracking plugin like AniList and MangaBaka, and it is the **default** one: its source
lives in this repository, it ships inside the app and is installed on first start. AniList and
MangaBaka stay in the separate plugin repository. Base contract:
[`2026-11-10-tracking-plugins.md`](2026-11-10-tracking-plugins.md) (spec v1).

## 1. What Bangumi does today (the parity bar)

Built in: `packages/fushi_engine/lib/media/tracking/bangumi_api_client.dart`,
`bangumi_tracking_provider.dart`, the Bangumi parts of `media_tracking_service.dart`, the Bangumi
block of `media_tracking_settings_body.dart`, `bangumi_watched_dialog.dart`, the control ops
`ctl_settings_body_tracking.dart` and the server CLI `tracking_commands.dart`.

| Behaviour | Built-in today | Through the plugin |
|---|---|---|
| Sign in | access token in prefs `media_tracking_bangumi_access_token`, checked with `GET /v0/me`; name in `media_tracking_bangumi_account_name` | `login` form method `token`; token and name in the plugin vault |
| Anime | marks the first N **main** episodes done (`PATCH …/episodes`, ordinal not `sort`), status `do` (3), `collect` (2) at the last episode, never back from 2 | host plans (`episode`, total = main episode count), plugin marks the first N main episodes |
| Books, volume mode | `vol_status`, raised only; `collect` when finished and `volumes` reached | `progressVolume`; plugin marks `finished` when `volumes > 0` |
| Books, chapter mode | `ep_status`, raised only; `collect` when the item is finished and `volumes <= 1` (and `vol_status 1` when `volumes == 1`) | new `Subject.singleVolume` (§2.3) |
| Chapter companion (`bookChapter`) | `ep_status` only, created as `do`, status otherwise untouched | same: the shared planner's `companion` rule keeps any existing status and never completes |
| Games | collection type 1..5 chosen by the user, written as is (no keep rule) | new kind `game` + mode `status` (§2.1) |
| Search / lookup by id | `POST /v0/search/subjects` per type (20 results), `GET /v0/subjects/{id}`; wrong type = not found | `trackingSearch` (20 results; the plugin cap was raised from 10 for every tracking plugin) / `trackingSubject` with `kind`; the host's kind check stays the wrong-kind guard |
| "Open on site" | `https://bgm.tv/subject/{id}` | new `tracking.subjectUrl` (§2.4) |
| "View all watched anime" | `GET /v0/users/{name}/collections?subject_type=2&type=2`, paged | new capability `trackingList` (§2.5) |
| Never lower progress | per writer | the shared planner (spec v1 §4) |
| Legacy auto-mapping (scraped ids, title fallback, chapter companion from the collection) | service code calling the API client | the same service code calling the provider's search / subject / entry calls (step 6) |

## 2. Contract gaps and the extensions (all optional; AniList / MangaBaka stay valid unchanged)

1. **Games.** `tracking.kinds` may contain `game`, `tracking.modes` may contain `status`; a manifest
   declares both or neither. `Subject.kind` may be `game` (no totals). For a `game` link the host
   sends `trackingEntry {op:'set', id, kind:'game', create, status}` with no progress. The status is
   the user's choice and is written as is (no keep rule; nothing to lower). `get` returns
   `{status, progress: 0}`. Host mapping of the stored Bangumi type (frozen in the outbox): 1
   planned, 2 completed, 3 current, 4 paused, 5 dropped.
2. **Second progress number**: already in v1 (`progress` + `progressVolume`). No change.
3. **`Subject.singleVolume?: boolean`**: the subject is one book (a volume, or a work with at most one
   volume), so finishing Fushi's item finishes the subject. Planner, `chapter` mode only: the entry
   completes when the item is finished and either the trusted chapter total is reached or
   `singleVolume`; when it completes through `singleVolume` and `finalVolume == 1`, `progressVolume
   1` is sent too if the site has less.
4. **`tracking.subjectUrl?: string | {[kind]: string}`**: `https://` template of a subject's web page with `{id}`
   (required) and optionally `{kind}`; its host must be `siteHost` or a subdomain of it. The host
   builds "Open on site" from it; absent = no link (as today for plugins). It may instead be an
   object of one template per kind (`{"anime": "https://anilist.co/anime/{id}", "novel":
   "https://anilist.co/manga/{id}"}`, for sites whose address does not follow the kind name): keys
   must be in `tracking.kinds`, each value follows the rule above, a kind left out has no link.
5. **Capability `trackingList`**: `{kind, status, offset}` -> `{items: [ListItem], next?: number}`,
   `ListItem {subject: Subject, status, progress, progressVolume?, updatedAt?: string (ISO 8601)}`.
   The host asks again with `offset = next` while `next` is present, at most 40 pages / 2000 items.
   Read only; used for "View all watched anime".
6. Reserved site ids: the engine keeps rejecting `mal`; `bangumi` is no longer rejected by the
   engine but is **pinned by the host** (§3).

The Rust manifest validation (`native/fushi_music/src/plugin/manifest.rs`), the developer kit
(`tools/tracking-plugin-sdk/`: rules, result checks, typings, guide) and the host
(`fushi/lib/src/media/tracking/plugin/`, `tracking_entry_plan.dart`) change together; the SDK sync
guard pins the lists.

## 3. Bundling and the reserved id

- Source: `plugins/tracking/bangumi/` (manifest, `main.js`, `bangumi.js`, tests with recorded /
  hand-written fixtures; no live calls). The kit gets a test harness
  (`tools/tracking-plugin-sdk/lib/harness.mjs`: the real sandbox runner with HTTP answered from
  fixtures and in-memory storage / vault); `fushi/test/media/tracking/bangumi_plugin_js_test.dart`
  runs the plugin tests with Node like the other `*_js_test.dart`.
- Packed asset, **checked in**: `fushi/assets/tracking_plugins/moe.fushi.tracking.bangumi.fushiplug`
  (unsigned, packed by the kit). The app needs no Node at build or run time; CI needs nothing new.
  A guard test checks that every file listed in the asset's `files.json` has the same SHA-256 as the
  source file, so the asset cannot drift from the source.
- Reserved-id check: a plugin claiming site id `bangumi` is registered only when its installed
  package digest (SHA-256 of `files.json`, computed by the engine at verify time) equals the digest
  of the asset bundled in this app build (the engine's `inspect` of the asset, computed once per
  start). Not a manifest flag: a third party cannot produce the digest without shipping the very
  same files. Any other package claiming `bangumi` is shown as "reserved site" and never registered.
- Implemented (step 4): `TrackingPluginManager.ensureBundled` pins `{pluginId, digest}` per site
  and installs; `bundled_tracking_plugins.dart` loads the asset; a side-loaded package claiming a
  reserved site is refused by `inspect` (`reserved_site`, translated message) and listed as
  "reserved site" if copied in by hand; `uninstall` of the bundled id throws `built_in`.
- Install: on start, before the manager's first `list()`, the host compares the installed
  `moe.fushi.tracking.bangumi` with the bundled digest and installs the asset when it is missing or
  different (an app upgrade replaces the installed bundled copy; a downgrade likewise). The enabled
  flag in `.state.json` is kept, so a user who turned it off keeps it off. The settings row says
  it is built in: it can be turned off, not removed (no Remove action).

## 4. Migration (first start with the plugin)

Runs once per device after the bundled plugin is installed and before the first sync:
- the token in `media_tracking_bangumi_access_token` is handed to the plugin's `login` with a host
  op `{op:'import', inputs:{token}}` (new optional login op, Bangumi only: stores the token without
  a network check so it works offline), the account name from `media_tracking_bangumi_account_name`
  goes along and becomes the stored account; then both prefs are cleared. Failure keeps the prefs and
  retries next start.
- Links keep provider id `bangumi`; per-kind switches and the enabled switch already use frozen
  Bangumi pref keys (`TrackingProviderPrefKeys.forProvider`), so they carry over untouched; the token
  scoped watermarks are not reset (same account).

- Implemented (step 5): `migrateBangumiTokenToPlugin` in
  `fushi/lib/src/media/tracking/plugin/bangumi_token_migration.dart` (provider op
  `PluginTrackingProvider.importLogin`, prefs rows deleted with `PreferencesRepository.removePref`).
  It acts only while the token pref holds a token, so it is idempotent without a flag; a disabled
  or missing bundled plugin keeps the pref. Wired into app start in step 6
  (`startBundledTrackingPlugins`, after the tracking module's install default is settled, because that
  decision reads the token pref); a moved token starts a sync.

## 5. iOS: decided (user, 2026-11-11): option (b)

iOS has no plugin JS engine (`native/fushi_ios_umbrella/Cargo.toml` builds `fushi_music` without the
`plugin` feature) and side-loaded plugins are store-gated there. Decision: **iOS keeps the built-in
Dart Bangumi; every platform with the plugin engine uses the bundled plugin.** Nothing Bangumi-related
is deleted from the Dart engine.

- One place decides: `isBangumiServedByPlugin` in
  `fushi/lib/src/media/tracking/plugin/tracking_plugin_gate.dart` (= `isTrackingPluginsAvailable`:
  store gate and plugin engine). The guard `ios_store_compliance_guard_test.dart` pins it and keeps
  `Platform.isIOS` out of `lib/src/media/tracking/`. Consumers ask the getter (or whether the
  manager exists), never the platform.
- Where it is true: the app builds the tracking service with `builtInBangumi: false` (the Dart
  provider is not even constructed), pins and installs the bundled package, moves the token (§4), and
  the `bangumi` site is served by the plugin provider as soon as the manager registers it
  (`setExtraProviders` puts it first). There is no moment where the token has moved and the Dart
  provider serves the site, or the reverse. Bundled plugin turned off = Bangumi off (nothing sent,
  links and queued rows kept, a token pref waits); the Dart provider never takes over. Where it is
  false (iOS, or a build whose native library lacks the plugin runtime): nothing changes, the token
  stays in prefs and the Dart provider serves `bangumi`.
- Callers never branch: `MediaTrackingService.isConfigured` / `accountName` / `loadStatus` /
  `loadWatchedAnime` / `canListWatchedAnime` / `subjectPageUrl` / `searchSiteSubjects` and the legacy
  auto-mapping (title search, chapter-companion baseline through the new `TrackingEntryReader`) ask
  whichever provider serves `bangumi`. `usesBuiltInBangumi` only decides which sign-in UI exists:
  Settings shows the old token block on the Dart path and the plugin's row (sign-in dialog, "View all
  watched anime") on the plugin path; the control channel's `connect` signs the plugin in with the
  token there. `connect` / `setAccessToken` throw `StateError` on the plugin path.
- The headless server (`packages/fushi_server`, `tracking_commands.dart`) has no plugin engine: it
  builds the service with the default `builtInBangumi: true` and stays on the Dart provider.
- Paired devices: the host's service-config snapshot exports the token pref only when the row
  exists. After the move the rows are **deleted** (not emptied), so a host on the plugin path no
  longer sends a Bangumi token and never erases a device's own token (an iOS device still uses its
  pref). A token arriving from a host that still keeps it in prefs (iOS, older build) lands in the
  pref and is moved into the vault on the next start. Sign-ins stay per device, in line with the
  agreed multi-device rule ("whoever plays sends; sign-ins stay per device").

## 6. Accepted differences

- Volume mode caps the written volume count at Bangumi's `volumes` when known (built-in did not cap).
- Anime: the plugin's `totalEpisodes` is the subject's main-episode count; the built-in compared with
  the fetched main-episode list. Same number except while Bangumi's `eps` lags its episode list.
- Legacy title auto-matching on the plugin path cannot read Bangumi's `platform` text, so a book
  search does not prefer manga over novels (or the reverse) by platform; the 0.92 score and margin
  rules are unchanged.
- "View all watched anime" on the plugin path has no covers (the plugin `Subject` has none).
- A media-server episode whose server carries a Bangumi id may be linked through the plugin's
  `trackingSubject` (the generic id linker); the built-in provider never tracked media-server
  playback. A MAL id never links (the plugin has no `trackingLookup`).

## 7. Step 6: routed, not deleted

Because iOS and the server keep the Dart provider (§5), nothing they use is deleted: the API client,
the provider, the token prefs, `connect` / `setAccessToken` / `accessToken`, the Settings token block
and the i18n keys stay. Removed because they were dead on every platform after the routing:
`MediaTrackingService.searchSubjects` / `getSubject` (the control channel now uses
`searchSiteSubjects`) and `showBangumiWatchedDialog` (now `showTrackingWatchedDialog`, which takes a
site id and works for every plugin with `trackingList`). Guards: `ios_store_compliance_guard_test`
(only the app model asks `isBangumiServedByPlugin`, as `builtInBangumi: !isBangumiServedByPlugin`),
`tracking_plugin_sdk_sync_guard_test` (search cap 20 in the kit, the host and the docs).

## 8. Order

(1) this plan; (2) contract extensions + kit + tests; (3) the plugin + harness tests; (4) bundling,
auto-install, reserved-id pin, iOS; (5) migration; (6) switch-over and deletion. Each step is a
separate commit, green before the next.
