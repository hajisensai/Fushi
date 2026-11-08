# SRS on the headless server (remote review, host-side sync, AnkiConnect)

Date: 2026-11-05, revised 2026-11-06. Status: **owner answered §11; waiting for go-ahead to implement**.

Follow-up to #2939 (`docs/agent/server-parity-gaps.md`, rows `srsRemoteStoreProvider` /
`onClientWrite` / `onClientUpload` and "SRS on the server").

## 1. Problem

When the desktop app is the interconnect host, it is also a full SRS device:

- paired devices can review directly on its collection (remote review, `srsRemoteStoreV1`);
- it reads and writes the SRS sync directory that clients sync into, so its own reviews reach them and theirs reach it;
- it answers AnkiConnect v6 on the Fushi API, so Yomitan / browser tools can add cards.

`fushi_server` does none of this. It already **stores** the SRS data: paired devices sync `fushi-srs/<profileUid>/v3/` into `<data>/sync-data/fushi-data/` like any other file. It also already ships the native SRS libraries (`libfushi_fsrs`, `libfushi_rwkv` in `release-server.yml`). What's missing is an SRS store on the server that reads that data and acts on it.

## 2. Goals and non-goals

Goals (v1):

1. **Remote review against the server.** A paired device can open "Review a paired device's decks", pick the server, and review exactly as it does against a desktop host. Same protocol, no client change.
2. **The server is a sync participant.** Reviews done on the server (remote review, AnkiConnect) are published to the sync directory and reach other devices. Other devices' changes are ingested so the server's collection stays current.
3. **AnkiConnect on the server**, off by default. Yomitan and similar tools can add notes to the server's collection, for example from a browser on another machine or from a phone over LAN.
4. **Lookup duplicate checks and mining into the server's collection** for phones without Anki or a local review copy (§4.8).

Non-goals (v1):

- No review UI in the WebUI. The server is a store and sync point, not a review client.
- No cloud sync channels on the server (Dropbox / WebDAV / …). It only syncs its own local directory, which is the one the clients write into.
- No RWKV scheduling on the server. FSRS only; the envelope reports `rwkv: false`, which clients already handle.
- No encrypted sync locations. v1 refuses them with a clear status (owner decision 2026-11-06, §4.3).
- No AnkiConnect GUI actions (`guiBrowse`, `guiEditNote` …): there is no GUI. They return the standard "unsupported" error.

## 3. Shape

```
paired device ──PUT fushi-srs/…──▶ FushiSyncServer ──onClientWrite──▶ ServerSrs.scheduleIngest()
paired device ──/api/srs/remote/*─▶ FushiSyncServer ──provider──────▶ SrsRemoteStoreService ─▶ SrsDbStore
Yomitan ───────AnkiConnect v6────▶ AnkiConnect listener (opt-in) ──▶ SrsAnkiConnectHandler ─▶ SrsDbStore
                                                                                │
ServerSrs: local-directory sync round (srsDefaultSyncRunner + media) ◀──────────┘ after writes
           → FushiSyncServer.notifySrsChanged() wakes clients' /api/srs/changes long-poll
```

New server file `packages/fushi_server/lib/src/server_srs.dart` (`ServerSrs`) owns all of it: storage, store, sync loop, remote store service and AnkiConnect handler. `headless_host.dart` only constructs it and wires three hooks, the same way `ServerSubtitleBackfill` is wired.

## 4. Design

### 4.1 Which profiles

**Several profiles per server (owner decision 2026-11-06).** People learning two languages keep one Fushi profile per language, and each profile has its own review collection. The server must serve all of them, not just one.

SRS data is keyed by a random profile uid, and the server has no profiles table by design (`profile_hub.dart` explains why). So the server **adopts profiles that already exist in its sync directory**:

- `srsListRemoteProfiles` (engine `srs_profile_link.dart`) already lists `fushi-srs/<uid>/` with device names, last update time and whether it has notes. The admin sees that list and ticks the profiles the server should serve.
- The choice is stored as config `srs.profiles: [<uid>, ...]` (yaml + settings page), plus `srs.default_profile: <uid>` (must be one of the list; empty = the first). An empty list = SRS off: no store opened, endpoints 404, capability bit off. That's today's behaviour, so upgrading changes nothing until an admin picks a profile.
- **One store per profile.** `ServerSrs` keeps a map `uid → ServerSrsProfile` (store, media store, sync loop, remote-store service, miner). Each profile syncs its own `fushi-srs/<uid>/` location independently; a failing or encrypted profile doesn't stop the others.
- Removing a profile from the list closes its store. In-flight remote-review clients of that profile get `profile_changed`, which the protocol already defines. Adding one opens it without a restart.
- There's no auto-pick, even when only one profile exists. Becoming a writer in someone's collection should be a deliberate admin action.
- **Which profile a request goes to.** Every client-facing path (remote review §4.4, AnkiConnect §4.5, mining and duplicate checks §4.8) names a profile uid or falls back to `srs.default_profile`. Clients send their **own active profile uid** by default: a phone on its "Chinese" profile reviews and mines into the server's "Chinese" collection without any setup, because both sides use the same uid for the same synced profile. If the server doesn't serve that uid, the request uses the default profile for reads and mining (and says so in the reply, §4.8), and remote review shows the profile list instead.

Admin surfaces:

- WebUI → new 复习 (SRS) card: profile list with checkboxes and a default marker, per-profile status, last sync, last error; AnkiConnect toggle and per-profile keys (§4.5);
- `GET/PUT /api/admin/srs`;
- `ctl srs [status|profiles|add <uid>|remove <uid>|default <uid>|off|sync [<uid>]]`, plus op-catalog descriptions as required for new ctl routes.

### 4.2 Storage and store

- `SrsStorage.open(path: <support>/srs.db)`, next to `fushi.db`, the same place the app uses.
- One `srs.db` holds every served profile (rows are already keyed by `profileUid`, as in the app). One `SrsDbStore` per served profile:
- `SrsDbStore.open(profileUid: <uid>, deviceId: ServerIdentity.deviceId, engine: FfiFsrsEngine.tryCreate(), deferMigration: false, styles: SrsStyleStore(...))`. There's no legacy SRS data on a server, so no deferred migration and no first-sync confirmation; the admin's pick is the confirmation.
- Media store: `<support>/srs_media/<uid>/`. `SrsMediaStore` is pure Dart (`crypto`, `path`) but lives in `fushi/lib/src/srs/`. **Move it to `fushi_engine/lib/srs/`**, delete the app copy, and update app imports.
- The day rollover hour comes from the synced profile settings when present (`SrsDbStore.dayContext`); otherwise it falls back to a new config `srs.rollover_hour` (default 4, same as the app default).
- If the native FSRS library is missing, the store still opens (browse and AnkiConnect work) and the envelope reports `sched: false`. This is the app's behaviour too.

### 4.3 Host-side sync (the server as a device)

- **Directory.** The server syncs exactly one location: `LocalDirectoryAssetStore(<sync-data>/fushi-data)`, directory key `srsInterconnectDirectoryKey(hostId)`. This is the same key the app host uses, so clients see the server as just another host.
- **Runner.** Reuse the app's production runner `srsDefaultSyncRunner` (prepare location → publish device info → `srsSync2Round`) and `srsDefaultMediaSyncRunner`. Both are free of Flutter but sit in `fushi/lib/src/srs/srs_sync_scheduler.dart`. **Move them**, plus `srsLogMigrationLeftover` and `srsLogV1MediaReport`, into `fushi_engine/lib/srs/sync2/srs_location_runner.dart`. `ErrorLogService` becomes `engineLog`. The app scheduler imports them from there.
- **Small engine helpers to move.** `srsIsHostSrsPath`, `srsHostUploadedSegmentDevice` and `srsInterconnectDirectoryKey` go from `fushi/lib/src/srs/srs_directory_key.dart` to the engine. The cloud-backend parts of that file stay in the app.
- **Triggers.** A round runs once at start and then:
  - on `onClientWrite` for an SRS path, debounced with the app's `kSrsHostWriteDebounce`;
  - after a server-side write (remote store `onWrite`, AnkiConnect writes), debounced;
  - on AnkiConnect `sync`;
  - on `ctl srs sync` / admin "sync now";
  - every 30 min as a safety net.

  Rounds are serialized: one at a time, and a trigger during a round queues exactly one more. Shutdown waits for the running round.
- **Wake clients.** After a round that uploaded something, call `FushiSyncServer.notifySrsChanged()`, as the app does.
- **Device names.** `onClientUpload` → `srsHostUploadedSegmentDevice` → `store.sync2DeviceHint(device, peerName)`. This is the same as the app's `_onHostClientUpload`, using the server's paired-peer table for names.
- **Encryption (owner decision 2026-11-06: refuse in v1).** If a profile's location is end-to-end encrypted, v1 **doesn't sync that profile**. Its status shows "location is encrypted, not supported by the server yet" and remote review, AnkiConnect and mining stay off for that profile, because the server can't read the data. Other profiles are unaffected. Storing a passphrase on the server would weaken end-to-end encryption against whoever controls the server box, so passphrase entry is a possible later follow-up, not v1. **The PR description and the server README must state this limitation.**
- **The server never deletes another device's data.** It runs the same engine, so retirement and cleanup rules are the engine's, unchanged.

### 4.4 Remote review

```dart
host.srsRemoteStoreProvider = () => serverSrs.remoteStore; // null while SRS off / not ready
```

`remoteStore` routes each call to the profile's own `SrsRemoteStoreService(readStore:, readMedia:, onWrite: scheduleUpload)`. Auth, idempotency, stale-card detection and `profile_changed` all live in the engine and the existing routes.

**Several profiles.** Today the wire already carries `profile?` on every call, but the host treats it as "the profile the client thinks is current" and answers `profile_changed` on a mismatch. With several profiles:

- the handshake (`profile` omitted) returns the default profile, as today, plus a new optional `profiles: [{uid, name, notes}]` list in the reply;
- a call that names a served uid goes to that profile's store instead of failing with `profile_changed`; an unserved uid still gets `profile_changed`;
- the app's remote-review picker tries the phone's own active profile uid first. If the server serves it, review opens straight away; otherwise the picker shows the server's profile list (from `profiles`) so the user can choose. Older clients that ignore `profiles` keep working against the default profile.

This is an engine change (`SrsRemoteStoreService` takes a `uid → store` resolver instead of one store) and a small app change in the remote-review picker. The desktop host's behaviour doesn't change: it serves only its current profile and never sends `profiles`.

### 4.5 AnkiConnect

- **New listener**, off by default:

  ```yaml
  ankiconnect:
    enabled: false
    bind: 127.0.0.1      # loopback only unless an api_key is set
    port: 8765
    api_key: ""          # required for any non-loopback request (enforced by the endpoint)
    cors_origins: []     # empty = engine default list
  ```

  It's a separate plain-HTTP listener because AnkiConnect clients expect `http://host:8765/` at the root path, while the interconnect port is TLS with pairing auth. The endpoint (`SrsAnkiConnectEndpoint`) already does origin checks, loopback-vs-key rules and body limits.
  Owner decision 2026-11-06: off by default, loopback-only unless a key is set.
- **Validation.** If `bind` is not loopback and no key is set, refuse to start the listener with a clear log line and admin status. Never start it open on the LAN.
- **Several profiles.** AnkiConnect has no profile field, so the **key picks the profile**: `ankiconnect.profile_keys: {<uid>: <key>}`. Yomitan for the Chinese profile is set up with the Chinese key, the Japanese one with the Japanese key. A request with `api_key` (the shared key) or from loopback without a key goes to `srs.default_profile`. Keys are generated in the WebUI and must be distinct. AnkiConnect's `getProfiles` / `loadProfile` return the served profiles' names, but `loadProfile` is not used for routing in v1, because it would switch the profile for every other tool talking to the same port.
- **Handler.** `SrsAnkiConnectHandler(store:, instanceId:, apiKey:, profileName:, onSync: syncNow, mediaSink: SrsMediaStore.store)`. No GUI callbacks. URL media fetch (`fetchUrl`) uses the engine's default app HTTP client, which goes through the proxy setup.
- **Hot apply.** Toggling `ankiconnect.*` in settings starts or stops the listener without a restart.
- **Not in the AI tool set.** AnkiConnect is a client-facing API, not an ops route.

### 4.6 Optimizer

`SrsOptimizationScheduler` (`fushi/lib/src/srs/srs_optimization_scheduler.dart`) is pure Dart with an isolate job, so move it to the engine. On the server it checks every 6 h and runs only when no remote-review request has arrived for 10 min. The app keeps its own idle gate (foreground, not on the review page). The applied parameters reach other devices through the normal sync.

### 4.7 Backup (fixes a gap in #2944)

Once `srs.db` exists, the server backup must snapshot it consistently, the way it does `fushi.db` with `VACUUM INTO`. A raw copy of a live WAL database can be torn. `createServerBackup` will:

- ask `ServerSrs` for a snapshot through the SRS core, either `VACUUM INTO` on the Rust connection or the core's backup command if one exists;
- exclude `srs.db-wal` / `-shm`;
- on restore, `srs.db` comes back like any other file under `support/`.

If #2944 merges first, this is a small edit in this PR.

### 4.8 Mining and lookup duplicate checks into the server's review collection

**Goal (owner, 2026-11-05).** Someone with no Anki, AnkiDroid or local review copy (a phone that only uses remote review) should see "already in your decks" while doing lookups, and new cards should land in the server's Fushi review collection.

**Today.**

- **Server side.** The server answers paired devices' `/api/mine*`, `/api/duplicate` and `/api/anki/*` through `ServerRemoteMiningService` (`remote_mining_host.dart`). It is backed only by the Anki landing collection (`anki_landing.dart` → `AnkiSyncMiner`). There is no review-collection path.
- **Desktop host, for comparison.** The desktop host routes peers' mining by its own mining target: `hostMiningAnkiRepositoryProvider` wraps the Anki backend in `SrsMiningAnkiRepository` when the host's target is Fushi review (`fushi/lib/src/anki/anki_view_model.dart`).
- **Client side, a gap for any host.** In `ankiRepositoryProvider`, the review wrapper is the **outermost** layer, outside `RemoteMiningAnkiRepository`. A phone whose mining target is Fushi review therefore checks duplicates and saves cards in its **own** review copy even with "mine to paired device" on. For a phone without a local copy, the check always says "not in your decks" and cards pile up on the phone. This affects desktop hosts too, not only the server.

**Server change.**

- Move `SrsMiner` and its helpers to the engine (see §5). They are free of Flutter and depend on `SrsDbStore`, `SrsMediaStore` and `AnkiNoteComposer`, which is in `fushi_anki_core`.
- New config `srs.mining_target: anki | review`. The default is `review` when a profile is selected and the Anki landing is not configured; otherwise `anki`. That way nothing changes for current Anki-landing users.
- New config `srs.mining_decks: {<uid>: <deck name>}` (missing = that profile's built-in default deck), with the built-in Lapis note type and the auto field mapping from `srsMiningFieldMappingsFor`.
- **Target list for clients.** New `POST /api/mine/targets` (peer token, empty body) returns what a phone may pick. It is POST like the other `/api/mine*` routes, so the phone reuses the shared pinned interconnect transport:

  ```json
  {"default": {"kind": "review", "profile": "<uid>", "deck": "<deck name>"},
   "review": [{"profile": "<uid>", "name": "Chinese", "decks": ["Default", "Mining"]}],
   "anki": {"decks": ["Mining", "..."]}}
  ```

  Decks are full deck names, not ids. That is the same form as the per-card deck override (`miningOverrides.deck`), which is how the target deck reaches the miner. `anki` is present only while the Anki landing is signed in; `review` lists only served, readable profiles. A host that doesn't implement targets answers 404 and the phone only offers "<host> default". **Not in v1:** the desktop host doesn't answer it yet. It ignores `target` and keeps landing cards by its own mining target.
- **Per-request target.** `/api/mine/forward`, `/api/mine` and `/api/duplicate` accept an optional `target: {kind, profile?, deck?}`. Missing = the server default (below). An unknown profile or kind falls back to the default and the reply says where the card actually went (`landed: {kind, profile, deck}`). When the phone had **explicitly** named a kind or deck that the host couldn't honour, the reply also carries `targetUnavailable: true`. A bare `{profile}` (the phone's own uid, i.e. "<host> default") that the host doesn't serve is not a fallback. Old clients don't send `target` and get today's behaviour.
- **Server default.** `srs.mining_target` decides `anki` vs `review`. For `review`, the profile is the phone's own active profile uid when the server serves it (sent as `target.profile` by new clients), otherwise `srs.default_profile`; the deck is that profile's `srs.mining_decks` entry.
- `ServerRemoteMiningService` dispatches on `srs.mining_target`. With `review`, these all go to `SrsMiner` on `ServerSrs`'s store:
  - `isDuplicate` → `SrsMiner.isDuplicate`, which uses `store.lookupTermStatus`;
  - `mineEntry`, `mineForwarded`, `mineImmersion` → `SrsMiner.mine`, rebuilding the forwarded media into local files exactly as the Anki path does;
  - then `scheduleUpload`.

  Anki-only operations (note-type templates, media dedup, `openWordInAnki`) return their "unsupported" result, as the desktop host does in review mode.
- **Capabilities.** No new `miningTarget` field: the phone reads the host's default from `/api/mine/targets`. `capabilities.mining` now reflects availability. The server reports `false` (and the mining routes 404) while it has neither a signed-in Anki landing nor a served review profile, and this changes with config without a restart (`FushiRemoteMiningAvailability`).

**Client change (app).**

- When "mine to paired device" is on, cards and duplicate checks go to the **host**. `ankiRepositoryProvider` skips the local review wrapper and sends lookups and new cards to the host. The client's own mining-target setting only applies while the toggle is off. This matches what the toggle already promises: cards go to the paired device.
- **The phone can choose where on the host (owner decision 2026-11-06).** Under the toggle, a new "Save to" row, filled from `GET /api/mine/targets`:
  - **"<host> default"** is the default selection. It sends no explicit kind or deck, only the phone's active profile uid, so the server's own setting decides (§4.8 server default).
  - The host's Fushi review profiles and decks, and its Anki decks when it has a signed-in Anki copy.
  - The choice is stored per paired host (`hostId`) on the phone, in one device-local pref `mine_to_server_targets` (`{<hostId>: {kind?, profile?, deck?, label?}}`). If the host later answers `targetUnavailable`, the phone resets that host to "<host> default" and shows a notice.
  - The row's subtitle shows the chosen location's label, saved when it was picked, for example "Fushi review · Chinese · Mining". The phone doesn't have to contact the host to show it.
  - The row also has a control-channel action (`interconnect.mine_to_server_target`, args `kind=default|review|anki`, `profile`, `deck`). It only accepts locations the host lists.
  - Strings go through `dart fushi/tool/i18n_sync.dart --add`.
  - The duplicate check uses the same target, so "already in your decks" means "in the collection your cards are going to".
- Background mining (`srsMiningBackground`) does not apply while forwarding, because the host must give a definite answer. That's the same as today's remote path.

### 4.9 What clients can and can't do against the server's collection

| Action | Phone with full local review copy | Phone with remote review only | Yomitan via server AnkiConnect |
|---|---|---|---|
| "Already in decks" on lookup | local copy (unchanged) | server (§4.8) | server (§4.5) |
| Add a card | local, or server if "mine to paired device" is on | server | server |
| Review | local, or remote | remote | — |
| Open the note in an editor from the lookup popup | local | not in v1 | not in v1 |

## 5. Code moves (app → engine, old copies deleted)

| From `fushi/lib/src/srs/` | To `packages/fushi_engine/lib/srs/` |
|---|---|
| `srs_media_store.dart` (`SrsMediaStore`) | `srs_media_store.dart` |
| `srs_sync_scheduler.dart`: `srsDefaultSyncRunner`, `srsDefaultMediaSyncRunner`, `srsLogMigrationLeftover`, `srsLogV1MediaReport`, `SrsLocalDirectory` | `sync2/srs_location_runner.dart` |
| `srs_directory_key.dart`: `srsIsHostSrsPath`, `srsHostUploadedSegmentDevice`, `srsInterconnectDirectoryKey` | `sync2/srs_host_directory.dart` |
| `srs_optimization_scheduler.dart` | `srs_optimization_scheduler.dart` |
| `srs_mining.dart`: `SrsMiner`, `srsSourceRefFromMiningContext`, `resolveSrsMiningDestination`, field-mapping helpers (lines 1–908); `visibleForTesting` → `package:meta` | `srs_miner.dart` |
| `srs_mining_target.dart`: `SrsMiningDestination` (and `SrsMiningTarget`; wire values frozen) | `srs_mining_target.dart` |

`SrsMiningAnkiRepository` stays in the app, because it extends the Flutter-side `BaseAnkiRepository`. It imports `SrsMiner` from the engine.

The app keeps the scheduler itself: cloud channels, notices, first-sync confirmation and Riverpod. The engine purity guard must stay green.

## 6. Config / API summary

- yaml: `srs: {profiles, default_profile, rollover_hour, mining_target, mining_decks}` and `ankiconnect: {enabled, bind, port, api_key, profile_keys, cors_origins}`.
- Client-facing: `GET /api/mine/targets`; optional `target` on `/api/mine*` and `/api/duplicate`; optional `profiles` in the remote-review handshake.
- Admin:
  - `GET /api/admin/srs`: status, profile, last sync and error, encrypted flag, AnkiConnect state;
  - `GET /api/admin/srs/profiles`;
  - `PUT /api/admin/srs`;
  - `POST /api/admin/srs/sync`.
- ctl: `srs status|profiles|use <uid>|off|sync`, plus `op_descriptions` entries.
- Capability: `srsRemoteStoreV1` is reported only while at least one profile is served and open.

## 7. Tests

- `server_srs_test.dart`, with a real `SrsStorage` on a temp dir and two simulated devices (engine test helpers that write a v3 location):
  - pick a profile → the store opens on that uid;
  - a client segment written through the server → ingest round → visible in the store;
  - a server-side write (remote store `answer`) → a round publishes a server segment → `notifySrsChanged` fires;
  - switching the profile → `profile_changed`; SRS off → endpoints 404, no capability bit;
  - an encrypted location → status `encrypted`, no sync, remote store off for that profile only;
  - two served profiles: a remote call naming profile B reads B's store; a segment for A only reaches A; removing B → B's clients get `profile_changed`, A keeps working.
- `headless_host_remote_services_test`: `srsRemoteStoreV1` reported only with a profile selected; `/api/srs/remote/call deckTree` round trip with a peer token.
- `server_ankiconnect_test.dart`:
  - listener off by default;
  - a non-loopback bind without a key refuses to start;
  - `version` / `deckNames` / `addNote` with media → note in the store and media in the media dir;
  - hot toggle;
  - a profile key routes `addNote` to its profile; the shared key / loopback goes to the default profile; duplicate keys are rejected.
- Mining (§4.8): with `srs.mining_target: review`:
  - `/api/duplicate` is false, then `/api/mine/forward` → the note is in the server store and media is in the media dir, then `/api/duplicate` is true;
  - with `anki`, the Anki-landing path is unchanged (existing tests);
  - `target` naming profile B's deck → the note lands there and `landed` says so; an unknown deck → default deck and `landed` says so; no `target` from an old client → server default;
  - `/api/mine/targets` lists only served profiles, and `anki` only while signed in.
- App: the "Save to" row defaults to "<host> default", and a stored choice the host no longer offers falls back with a notice; the remote-review picker opens the phone's own profile directly when served, otherwise lists the server's profiles.
- App: `ankiRepositoryProvider` with "mine to paired device" on and target = review → requests go to the remote client, not the local `SrsMiner`. There is a provider test for this.
- Backup: a backup taken while SRS is open restores to a readable `srs.db` with the same notes.
- App: run the moved files' existing tests from their new homes, plus `fushi_engine_purity_guard_test` and `srs_remote_store_parity_guard_test`.
- Manual check before calling it done:
  - the emulator app pairs with the server;
  - review two cards remotely;
  - a third device (or the desktop app synced over interconnect) sees those reviews.

## 8. Rollout

One PR, in order:

1. Engine moves. No behaviour change; app tests green.
2. `ServerSrs`: storage, store, sync loop and remote store.
3. AnkiConnect listener.
4. Mining dispatch on the server, plus the client change and capability field (§4.8).
5. Backup snapshot.
6. WebUI, admin API, ctl, README, CI fsrs step.

Size: L (a bit larger than backup + self-update combined, because of several profiles and the target picker).

## 9. Impact review: everything this plan touches

**Server (`packages/fushi_server`)**

- New files: `server_srs.dart`, `admin/admin_srs.dart`, `ankiconnect_listener.dart`.
- Edited files:
  - `headless_host.dart`: wiring, plus `miningTarget` in capabilities;
  - `host_bindings.dart`: remove `TODO(srs-ankiconnect)`;
  - `config/server_config.dart`: `srs`, `ankiconnect`;
  - `admin/admin_api.dart` and `admin/web_ui.dart`: 复习 card;
  - `ctl/ctl_commands.dart`;
  - `admin/admin_ops.dart`: describe `srs status/profiles` read-only for the AI tool set; keep `add`/`remove`/`default`/`off` out of it, because choosing collections is an owner decision. Added later: `server.srs.sync` (irreversible, user confirms) and undoable `mining-target.set` / `mining-deck.set` / `rollover-hour.set`; AnkiConnect settings stay out;
  - `remote_mining_host.dart`: §4.8 dispatch;
  - `backup/server_backup.dart`: §4.7, only once #2944 is merged;
  - `README.md`.
- `ServerDataLock` and offline CLI commands: nothing opens `srs.db` offline in v1. `backup restore` already holds the lock, so `srs.db` is closed during restore.

**Engine (`packages/fushi_engine`)**

- New homes for the moves in §5.
- `fushi_sync_server.dart`: the capabilities field `miningTarget`, a nullable provider set by both hosts.
- The engine purity guard must stay green. The moved files are free of Flutter today (checked imports): `SrsMiner` needs `package:meta` instead of `flutter/foundation`.

**App (`fushi/`)**

- Import updates wherever the moved code is used: the SRS runtime, scheduler, providers, `srs_profile_stores.dart`, `anki_view_model.dart`, `app_model.dart` and others. These are mechanical.
- `anki/anki_view_model.dart`: `ankiRepositoryProvider` skips the review wrapper while "mine to paired device" is on (§4.8). This is the only behaviour change for app users.
- `sync/fushi_server_controller.dart`: report `miningTarget` from `hostSrsMiningTarget`.
- The "mine to paired device" setting row: a subtitle showing the host's target, read from capabilities. It needs new i18n keys through `dart fushi/tool/i18n_sync.dart --add` (never by hand), plus a `gen_i18n` rerun before tests.
- Tests that move with the code (SRS miner, media store, scheduler runner and optimizer tests), plus `srs_remote_store_parity_guard_test` and `fushi_engine_purity_guard_test`.
- No change to the remote-review client: it already probes `srsRemoteStoreV1` on every paired host.

**CI**

- `server-gate.yml` doesn't build `libfushi_fsrs`, but the SRS store needs it (`SrsCore` loads `fushi_fsrs`). The server's SRS tests would fail or skip in CI without it. Two changes are needed:
  - add a `setup-fushi-fsrs` composite action, modelled on `setup-fushi-rwkv`, and use it in `server-gate.yml`;
  - add `native/fushi_fsrs/**` to that workflow's path filters.
- `release-server.yml`: nothing. The Linux `.so` and Windows `.dll` for `fushi_fsrs` and `fushi_rwkv` are already bundled.

**Docs**

- `docs/agent/server-parity-gaps.md` (arrives with #2939): close the SRS rows and the "SRS on the server" item.
- `docs/specs/2026-11-01-srs-remote-review-design.md` §1: "any Fushi" becomes "any Fushi or `fushi_server`".
- `docs/agent/subsystem-map.md`: one line pointing at `server_srs.dart`.
- Coordination brief and claim.

**Open PRs this collides with.** All of these touch `headless_host.dart`, `server_config.dart` or `web_ui.dart`:

| PR | What |
|---|---|
| #2939 | parity |
| #2943 | self-update |
| #2944 | backup |
| #2945 | leaderboard link |
| #2946 | subtitles |

Plan: start the C branch from `develop` once those merge. If they're still open when work starts, stack it on #2944 (needed for §4.7) and rebase afterwards.

**Out of scope, unchanged.**

- The desktop app's own AnkiConnect, cloud sync channels and RWKV.
- iOS store-compliance rules: this is server-side, and the client change doesn't touch the three gated areas.
- Anki-landing users: the default `srs.mining_target` keeps them on `anki`.

## 10. Related findings (2026-11-05 device check of the Anki path)

Checked on the emulator against the released `fushi_server` 0.1.0-23883 (Windows), with a local official Anki sync server (`anki` 26.09.4) standing in for AnkiWeb. The phone used Fushi with no Anki or AnkiDroid installed, mining target = Anki and "Mine to Fushi Interconnect server" on.

| Step | Result |
|---|---|
| "Desktop Anki" adds 食べる, syncs; server logs in to the sync server | server downloads the collection |
| Phone lookup of 食べる (Android "process text" popup) | ✓ (already in decks), answered by the server |
| Phone lookup of 走る | + (not in decks) |
| Tap + on the phone | card added on the server; popup turns ✓; `/api/duplicate` true |
| "Desktop Anki" syncs | 食べる, 飲む, 走る all present |

Problems found:

1. **No periodic pull on the server's Anki copy.** The session syncs only at startup, after it adds a card itself, or on manual "sync" (`anki_sync_session.dart` `scheduleSync` callers; `anki_landing.dart` `start`). A card added in desktop Anki or AnkiDroid stays invisible to the server's duplicate check until one of those happens. This was reproduced: 飲む stayed `duplicate:false` until `ctl anki sync`.

   Fix (small, separate from C): a periodic pull while signed in, for example every 15 min, respecting the session's rate-limit cooldown, plus a throttled pull on the first duplicate check after a long idle.
2. **The Windows server release doesn't bundle `fushidicts_ffi.dll`.** Remote dictionary lookup through a Windows server is unavailable; the log says so. It doesn't affect duplicate checks, because the phone uses its own dictionaries.
3. **Red-screen assertion after pairing** (`framework.dart: _dependents.isEmpty`) on a 2026-10-29 debug build. It's not checked on current develop yet, and needs a repro on a fresh build before filing a bug.

## 11. Owner decisions (2026-11-06)

1. **Profiles: several per server.** People learning two languages keep one profile per language. The server serves every profile the admin ticks, one store each (§4.1). Remote review, AnkiConnect and mining each pick a profile: remote review and mining default to the phone's own active profile, and AnkiConnect picks by key (§4.4, §4.5, §4.8).
2. **Encrypted locations: refused in v1.** Clear per-profile status, other profiles unaffected (§4.3). **Put this limitation in the PR description** and the server README.
3. **AnkiConnect: off by default, loopback-only unless a key is set** (§4.5).
4. **Where mined cards go: the phone can choose.** Under "mine to paired device", a "Save to" row lists the host's Fushi review profiles and decks and its Anki decks. The default is "<host> default", which leaves it to the server's setting (§4.8).

## 12. PR description checklist

- Limitation: profiles whose sync location is end-to-end encrypted are not served in v1.
- Wire additions are all optional and backward compatible: `profiles` in the remote-review handshake, `target` / `landed` / `targetUnavailable` on mining, `POST /api/mine/targets`.
- Admin surface: `GET|PUT /api/admin/srs` (PUT also takes `addProfiles` / `removeProfiles`, so `ctl srs add|remove` is one request), `GET /api/admin/srs/profiles`, `POST /api/admin/srs/sync`, `ctl srs …`, WebUI 复习 page. AnkiConnect keys are never echoed. No server op-catalog entries in v1.
- Server backups now carry a consistent `srs.db` snapshot instead of the raw file and its `-wal` / `-shm`.
- CI: `server-gate.yml` builds `native/fushi_fsrs` and exports `FUSHI_FSRS_LIB` for the server tests.
- App behaviour change: with "mine to paired device" on, duplicate checks and cards go to the host instead of the phone's own review copy.
