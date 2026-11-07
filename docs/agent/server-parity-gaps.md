# fushi_server parity gaps

Developer-facing list of what the headless server (`packages/fushi_server`) still does
not do compared with the app acting as host. Keep it short and current: when a gap closes,
delete its line in the same PR.

Library root kinds the server scans today: `video`, `book`, `manga`, `audiobook`
(`kServerLibraryRootKinds` in `packages/fushi_server/lib/src/config/server_config.dart`;
yaml loading, the admin API and the WebUI all use that list).

## Host hooks: app vs server

Both sides run the same engine host, `FushiSyncServer`
(`packages/fushi_engine/lib/sync/fushi_sync_server.dart`). The app builds it in
`fushi/lib/src/sync/fushi_server_controller.dart`, the server in
`packages/fushi_server/lib/src/headless_host.dart`. A hook left null turns its endpoints
into 404/501 and clears its `/api/capabilities` bit, so diff the two call sites first when
checking parity. Hooks the server leaves null today:

| Hook | Effect on the server | Status |
|---|---|---|
| `srsRemoteStoreProvider`, `onClientWrite`, `onClientUpload` | No remote review (`/api/srs/remote/*` 404), no host-side SRS sync | Gap. Needs an SRS store on the server first (see "SRS on the server"). Size L, needs a spec. |
| `hostSelfUpdater` | `/api/host/update` 404, `hostUpdate=false` | Gap. Implement `HostSelfUpdater` (`fushi_engine/lib/sync/host_update/host_update_protocol.dart`) by fetching the `hajisensai/fushi-server` release asset for the running OS, unpacking it next to `bin/`, and exiting for the service manager to restart. The app version is `fushi/lib/src/updates/host_self_update_service.dart`. Size M. |
| `leaderboardLinkHost` | Paired devices can't sign in to the Fushi account through the server | Gap. The server already stores per-profile accounts in the app's file format (`leaderboard_store.dart`); this needs an `InterconnectLeaderboardLinkHost` adapter on top. Size S/M. |
| `videoRemoteService`, `gameStreamService` | Remote playback and game streaming are off | Not applicable: both need a display or a running game. |
| `LocalLibraryHostService.onlineMangaReader` | Online-manga chapters that weren't downloaded aren't served | Not applicable: the server has no online-source runtime. |

The other hooks are wired on both sides: pairing, peer tokens, `hostId`, public URLs, P2P,
graphic-subtitle export, `videoSubtitleBackfill`, OCR, jobs, downloads, subscriptions,
assistant, lookup, history, mining, dictionary media/styles and prefs.

Host-side settings that the app keeps in `preferences` live in `fushi_server.yaml` on the
server when nothing on the server can write that preference. Example: the Chinese
Simplified/Traditional lookup toggle. The app reads the `lookup_chinese_script_variants`
preference; the server reads `lookup_chinese_script_variants` in the yaml
(`ServerConfig.lookupChineseScriptVariants`, off by default, editable in the WebUI). It only
applies to requests that don't send `zhScriptVariants` themselves (the browser extension and
older apps).

## Music libraries: deliberately deferred

Music was left out of the server's first library-kinds pass (2026-10-28) because of its
size; see the plan below. The server rejects `kind: music` on
purpose: yaml loading and `POST /api/admin/libraries` fail with a message that points
here, and `_purgeRoot` in `packages/fushi_server/lib/src/admin/admin_api.dart` throws for
`SourceLibraryKind.music`. Do not "quick fix" this by letting music roots through. Without
the host routes below, a client cannot see a scanned music library at all.

The full plan needs its own design spec under `docs/specs/`. Size: L/XL.

1. Move the scanner stack from `fushi/lib/src/media/music/` into `packages/fushi_engine`:
   `music_library_scanner.dart`, `disc/music_disc_import.dart` and
   `metadata/music_scrape_service.dart`. Inject the app-only parts: the
   `onMusicSourceScanned` callback, paths, and the AcoustID key. Resolve the
   `theme_song_detector` dependency, which is reached through `music_scrape_service.dart` /
   `music_video_service.dart`. Keep `fushi/test/build/fushi_engine_purity_guard_test.dart`
   green: no Flutter, plugins or `package:fushi` in the engine.
2. Server scan: add `case 'music'` to the `scanAll` switch in
   `packages/fushi_server/lib/src/library_scanner.dart`, plus prune. Music soft-deletes
   through the music scanner, not through `pruneMissingBookRows`. Add `music` to
   `kServerLibraryRootKinds` and handle it in admin purge.
3. Native: build and bundle `native/fushi_music` in `.github/workflows/release-server.yml`
   and `build-multiplatform.yml`. Copy how `fushi_fsrs` is done: a Rust cache, a Linux
   x64 build, `bin/../lib/` lookup, and a hard failure when the build fails.
4. The big part is the host surface. This needs new interconnect routes
   `/api/library/music*` (tracks, albums, artists, ranged audio streaming, covers,
   lyrics), `Remote*` DTOs, a capability bit, wiring in `LocalLibraryHostService`, an
   app-side remote client and UI, and op-catalog descriptions for any new ctl routes.

## Other known gaps

- **SRS on the server**: there is no SRS store or profile wiring yet, so there is no
  AnkiConnect layer on the server (`TODO(srs-ankiconnect)` at the top of
  `packages/fushi_server/lib/src/host_bindings.dart`). The same missing store keeps
  `srsRemoteStoreProvider` / `onClientWrite` / `onClientUpload` null (table above). With
  a store, both would reuse the engine pieces the app uses: `SrsRemoteStoreService`
  (`fushi_engine/lib/srs/srs_remote_store.dart`) and `SrsAnkiConnectHandler`.
- **Backup**: there is no `backup` CLI command or admin endpoint. App backups
  (`createBackup` / `restoreBackup`) live in `fushi/lib/src/sync/backup_*`.
- **Jellyfin / Emby / Plex as library sources**: the `MediaServerBrowser` implementations
  live in `fushi/lib/src/sync/`, not in the engine. The server only has read-only Plex
  browsing (`media-server plex`). It cannot register a media server as a library source.
- **Scraping for books, manga and music**: none. Only video scraping runs on the server
  (`video_scrape_host.dart`).
- **Manga PDF**: not imported. Rasterizing needs the app's pdfium/pdfrx. Downloads with a
  PDF are blocked with `unsupportedOnThisHost`, and manga roots skip `.pdf`.
- **Subtitles (what is still app-only)**: downloads source subtitles and
  `POST /api/library/videos/<id>/subtitle/backfill` works on the server (one provider
  assembly in `packages/fushi_server/lib/src/server_subtitle_providers.dart`; the backfill
  wiring in `packages/fushi_server/lib/src/server_subtitle_backfill.dart`; the backfill
  service lives in `packages/fushi_engine/lib/media/video/subtitle/`). Done on the server
  (2026-11-05, same engine code as the app): backfill after a scrape (`onWorkScraped` on
  the shared coordinator, limited to downloaded files like the app), the periodic retry of
  downloads that finished without a subtitle (`download_subtitle_retry.dart`, now in the
  engine), AI reordering of candidates (the `ai:` provider is also assigned to
  `AiFeature.videoSearch`), and the app's Jimaku provider (search by AniList / TMDB id,
  now `packages/fushi_engine/lib/media/video/jimaku_subtitle_provider.dart`). Still missing:
  - AJATT (`fushi/lib/src/media/video/subtitle/ajatt_*`) is app-only;
  - the download pipeline reads subtitle providers when the pipeline is (re)built (start,
    or after resource indexers are saved). A key pushed later over interconnect needs one
    of those, or a restart. Backfill reads them per request.
- **Audiobooks with audio only (no subtitle)**: these are not imported, either from an
  `audiobook` library root (counted as `audiobooksNeedSubtitle` in the scan summary) or
  from a download (`buildServerDiscoveryImporters` in `discovery_import_host.dart` blocks
  `TranscribeAudiobookPlan` with `audiobookMissingSubtitle`). The server does have an ASR
  runner (`AsrHostJobRunner`, `kind=asr`), but it serves client-submitted jobs: it takes
  uploaded or `videoId` input, writes `transcript.srt` into the job dir, and the client
  pulls the result. Using it here is not a small change. It would need all of the
  following:
  - a transcription language (download plans and library roots don't carry one), so a
    new config key;
  - a check that the model is ready (models are pulled explicitly with
    `fushi_server models pull`);
  - a durable queue that survives restarts, because a transcription takes hours and
    can't run inline in the download pipeline or the scan;
  - a completion hook into `importTranscribedAudiobook`;
  - task states that let a download report "waiting for transcription" instead of
    "needs attention".

  Until that exists, run `fushi_server transcribe`, then either use
  `audiobook align --srt …` or drop the `.srt` next to the audio and rescan.
- **Audiobook roots (limits of the first version)**: audio is imported by reference
  (`copyAudio: false`). It stays in the root and is never copied into the data dir. A book
  is tracked by its folder (or by a loose audio file in the root). Files added to an
  already-imported folder are not picked up again. Remove the book, or purge the root, to
  re-import it. When a book title already exists in the library, the folder is skipped
  and not adopted. Root folders are recorded in `media_sources` with
  `mediaKind = 'audiobook'`. This value is server-only: it is not in the shared
  `SourceLibraryKind` enum, because adding it would touch every exhaustive switch in the
  app.
