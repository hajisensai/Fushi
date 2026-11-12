# Tracking site plugins (v1)

Status: implemented. Owner decision 2026-11-10: tracking sites
other than Bangumi are not built in; they are plugins the user installs. Tracking has **its own
plugin system** (own plugin kind, vocabulary, manager, data folder, credential domain, settings page,
developer kit). It shares only the sandbox **engine** with music plugins
([`2026-10-28-music-plugins.md`](2026-10-28-music-plugins.md) §2 package format, §3 runtime): the
QuickJS runtime, package verification, network policy and vault in `native/fushi_music/src/plugin/`.
A music plugin can never be loaded as a tracking plugin, or the reverse.

## 1. Scope

- A tracking plugin lets Fushi read and write the user's list entry on one site, look subjects up by
  id, and optionally search by title. Fushi keeps every decision: when to send, what to link, and
  the rule that progress is never lowered.
- No plugin repository. The app bundles three site plugins (Bangumi built in; AniList and MangaBaka
  included and removable: [`2026-11-11-bangumi-bundled-plugin.md`](2026-11-11-bangumi-bundled-plugin.md)
  §3 and §9). Any other plugin is installed from a local `.fushiplug` file after the user confirms
  name, permissions, network domains and signer.
- Not on iOS (downloads and runs third-party code; gated like music plugins). Not in the headless
  server. No plugin UI: sign-in is rendered by the host from the plugin's data.

## 2. Manifest

Package format, limits, signature and trust are exactly music §2. Differences:

```json
{
  "schema": 1,
  "kind": "tracking",
  "id": "moe.example.tracking.site",
  "name": "Example",
  "version": "0.1.0",
  "api": 1,
  "entry": "main.js",
  "capabilities": ["login", "account", "trackingEntry", "trackingSubject", "trackingSearch", "trackingLookup"],
  "permissions": ["network", "credentials"],
  "network": { "domains": ["api.example.org"], "methods": ["GET", "POST"] },
  "tracking": {
    "siteId": "example",
    "siteHost": "example.org",
    "kinds": ["anime", "manga", "novel"],
    "defaultKinds": ["anime"],
    "modes": ["episode", "chapter", "volume"],
    "requestsPerMinute": 30
  }
}
```

- `kind`: `"music"` (default when absent, all music rules unchanged) or `"tracking"`.
- With `kind: "tracking"`:
  - `capabilities` ⊆ { `login`, `account`, `trackingEntry`, `trackingSubject`, `trackingSearch`,
    `trackingLookup` }, and must contain `login`, `account`, `trackingEntry`, `trackingSubject`.
  - `permissions` ⊆ { `network`, `storage`, `credentials` }; `network` and `credentials` are required.
    `webAuth` and `insecureHttp` are rejected.
  - `searchTypes` must be absent or empty.
  - `tracking` is required:
    - `siteId`: `[a-z0-9]{2,32}`, not `mal` (reserved id space; `bangumi`: see §4a). The provider id stored with links
      (`media_tracking_mappings.provider`) and the key other sites use to cross-reference this one.
      Two enabled plugins with the same `siteId` are not allowed; the second is not registered.
    - `siteHost`: a plain host name (no wildcard, no scheme). Used to recognize a pasted link.
    - `kinds`: non-empty ⊆ { `anime`, `manga`, `novel` }. `defaultKinds` ⊆ `kinds` (may be empty):
      the kinds switched on by default for this site.
    - `modes`: non-empty ⊆ { `episode`, `chapter`, `volume` }.
    - `requestsPerMinute`: 1–600. The host delays the plugin's HTTP requests to stay under it.
- With `kind` absent or `"music"`, a `tracking` object is rejected.

## 3. Functions

The entry module exports one function per capability (may be async). Ids are positive integers.

| Capability | Argument | Result |
|---|---|---|
| `account` | `{}` | `{ loggedIn: bool, name?: string }` |
| `login` | music §4.1 (`methods` / `begin` / `submit` / `logout`) | music §4.1. v1 host renders only `form` methods (plus `appUrl`, an https link in the network grant, shown as "Open site") |
| `trackingSubject` | `{ id, kind? }` | `Subject` or `null`. `kind` is sent whenever the host knows which kind it expects |
| `trackingSearch` | `{ query, kind }` | `{ items: [Subject] }` (host uses the first 20) |
| `trackingLookup` | `{ idType, id, kind? }` | `{ items: [Subject] }` (host uses the first 20): the subjects on this site for another id space. `idType` is `"mal"` or another site's `siteId` |
| `trackingEntry` | `{ op: 'get', id, kind }` | `Entry` or `null` (not on the user's list) |
| `trackingEntry` | `{ op: 'set', id, kind, create: bool, status, progress?, progressVolume? }` | `null`. Only the given fields change. `create: true` = the host saw no entry (create it, or update it if one appeared meanwhile); `create: false` and the entry is gone = throw `not_found:` |

```ts
Subject { id: number, name: string, kind: 'anime' | 'manga' | 'novel',
          titles?: string[],        // every known title, any script
          authors?: string[],
          totalEpisodes?: number, totalChapters?: number, finalVolume?: number,
          finished?: boolean,       // the work itself is complete
          linkedIds?: { [idType: string]: number } }   // e.g. { mal: 30831, anilist: 44893 }
Entry   { status: 'planned' | 'current' | 'completed' | 'paused' | 'dropped' | 'repeating',
          progress: number,         // episodes (anime) or chapters
          progressVolume?: number } // volumes
```

`kind` on `trackingEntry` is the kind of Fushi's item (`anime` / `manga` / `novel`), for sites whose
ids are per list. `Entry.progress` counts episodes for anime and chapters for manga and novels; a
site without chapter counts returns 0 there and uses `progressVolume`. `account` results may carry
other fields; the host reads only `loggedIn` and `name`. `login` calls carry `platform` as in music.

Errors: a thrown `Error` whose message starts with `unauthorized:` (sign in again),
`rate_limited:` (stop this sync round), or `not_found:` (permanent for this item); anything else is
treated as temporary and retried later. The rest of the message is shown to the user. Throw a plain
`Error`: the host recognizes a prefix only at the start of the message of a built-in error type.

`trackingSubject` may return a subject whose `id` differs from the one asked for (the site merged
the entry into another). The host then uses the returned id for that item's `trackingEntry` calls.

One call should make only a few requests: time spent waiting for the request budget
(`requestsPerMinute`) counts toward the call's timeout (60 s).

## 4. Host rules (not negotiable by a plugin)

- The host reads the entry, plans, then writes: progress is never lowered; a `completed` or
  `repeating` entry keeps its status; `completed` is only written when Fushi's item is finished and
  the site's total (when known) is reached. A chapter-companion write (the chapter count kept next to
  a volume link) keeps any existing status and never completes. One planner for every plugin
  (`packages/fushi_engine/lib/media/tracking/tracking_entry_plan.dart`).
- Untrusted results: strings trimmed and capped (name / title 500, at most 50 titles, 20 authors),
  counts must be non-negative integers else treated as missing (an entry whose own counts or status
  cannot be read is left alone: nothing is written), a subject without a positive `id`,
  a `name` or a known `kind` is dropped, `linkedIds` keeps at most 16 positive integers.
- Credentials live only in the plugin vault (`fushi.credentials`), in the tracking domain; removed
  with the plugin. Links, suggestions and queued updates are kept when a plugin is disabled or
  removed, and are used again when a plugin with the same `siteId` is back.

## 4a. Optional extensions (2026-11-11)

Added for the bundled Bangumi plugin ([`2026-11-11-bangumi-bundled-plugin.md`](2026-11-11-bangumi-bundled-plugin.md) §2);
all optional, existing plugins stay valid: kind `game` with mode `status` (declared together; a game write
carries only the user's status, written as is), `Subject.singleVolume`, `tracking.subjectUrl` (page address
template, or an object of one template per kind), capability `trackingList` (the user's list by status,
paged with `offset` / `next`), and the login op `import` (bundled plugin only: the host moves a sign-in
saved before the plugin existed). The engine no longer rejects `siteId: "bangumi"`; the host registers it only for the bundled package (digest pin).

## 5. Host wiring

- Data: `<database dir>/tracking_plugins/` (`<id>/`, `.storage/`, `.state.json`, `.credentials/`);
  `.credentials/` is excluded from Android backup like the music one.
- App: `fushi/lib/src/media/tracking/plugin/`. `tracking_plugin_engine.dart` is the only file that
  touches the shared engine (`package:fushi_music` plugin FFI), so the engine can later move to its
  own native crate without touching the rest.
- Settings › Media tracking › Tracking plugins: install, enable / disable, remove, account.
- Developer kit: `tools/tracking-plugin-sdk/`.
