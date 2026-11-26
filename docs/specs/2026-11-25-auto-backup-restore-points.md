# Auto backup and update rollback (restore points)

Status: phase 1 implemented (branch `feat/auto-backup-p1-update-snapshot`), phase 2 implemented (branch
`feat/auto-backup-p2-scheduled`, stacked on phase 1), phase 3 user folder on mobile implemented (branch
`feat/auto-backup-p3-offdevice`, stacked on phase 2); cloud copies are a proposal only. Owner: auto-backup session. Proposal with the comparison of other apps:
https://claude.ai/artifact/GzX9ynemY4FxoXn85dbvCp (private; summary below so this file stands alone).

## Problem

- If an update migrates `fushi.db` and the user reinstalls the older build, the old build throws
  `FushiDatabaseDowngradeException` and the downgrade screen has no way back. Nothing copies the DB
  before `onUpgrade` runs.
- The only backup is the manual export. Cloud / Interconnect sync hold the latest state only, so a bad
  change syncs everywhere.
- The SRS auto backup (Anki-style retention, "restore to this point") was removed with SRS sync v2, but
  the Anki-migration notice still pointed users at it (fixed in phase 2, see D6).

## Phase 1 as implemented (2026-11-25)

Differences from the design text below, and details the design left open:

- **Where the main-DB snapshot runs.** After `_openWithRecovery`, not before it: the probe connection has
  recovered stale `-wal` / `-shm` by then, and drift's background connection is still lazy (the migration
  only runs on the first query's `ensureOpen`). `user_version` is read on a raw read-only connection.
- **Ids and files.** `<UTC yyyyMMdd-HHmmss-SSS>-<database>-<kind>[-n]`, e.g.
  `20261125-142530-123-fushi-pre_update`. Both databases share one `restore_points/`; each side only
  cleans incomplete dirs whose id carries its own database. Meta keys: `format`, `kind`, `database`
  (`fushi` / `srs`), `createdAtMs`, `fromSchema` (schema of the copy), `toSchema`, `appVersion`
  (injected by the app via `RestorePointStore.appVersion`; Rust writes `null`), `files[{name,size}]`.
- **Status is per database:** `restore_points/last_snapshot_status.<database>.json` (Dart and Rust
  would race on one shared file). The startup notice marks it `acknowledged` before showing it.
- **Retention:** newest 3 `pre_update` and newest 3 `pre_rollback` per database.
- **Rollback journal:** `restore_points/rollback_pending.json` records each database's step
  (`pending` → `moved` → `copied`). Order per database: move `-wal` / `-shm` / `-journal`, then the
  main file, into a new `pre_rollback` point; copy the snapshot to `<live>.rollback-tmp`, rename it into
  place; write the `pre_rollback` meta last. `recoverPendingRollback` replays the recorded step; the app
  calls it before constructing `FushiDatabase`, and `_openDb` calls it again (main process only). The
  target snapshot is `quick_check`ed and the live file is test-renamed before the journal is written,
  so a locked or bad file fails without leaving a journal behind.
- **Review DB.** Generation 4 has **no in-place schema upgrade today**: `check_kind` refuses every
  `schema != SCHEMA` (older or newer). So the Rust writer (`store/gen4/restore_point.rs`,
  `snapshot_before_upgrade`) exists and is tested but is not called yet; `check_kind` documents that a
  future upgrade ladder must call it first. A too-new `srs4.db` has no dedicated surface in the app
  (it is a generic SRS open failure inside the review module, the app itself still starts), so there is
  no separate SRS rollback screen. When the main DB is rolled back, the review DB goes with it if an SRS
  `pre_update` point was created between that main point and the next one **and** `srs4.db` still sits
  at that point's `toSchema` (`RestorePointStore.companionSrsPoint`); this is dormant until the ladder
  exists.
- **UI.** `RestorePointRollbackPanel` (downgrade screen; unrecoverable-DB screen unless the cause is a
  full disk) lists compatible points (date, schema from → to, size), confirms with
  `showFushiConfirmDialog` (destructive), runs `AppModel.rollbackToRestorePoint` (closes SRS + drift
  first) and restarts via `backupImportRestart`. Storage page shows `restore_points/` as one labelled
  read-only entry under "Database and internal data".

## Phase 2 as implemented (2026-11-25)

- **Store.** Same `restore_points/` store. `RestorePointKind.forced` became `preOperation`
  (`pre_operation`, meta `reason`: `replace` / `sync_download` / `srs_migration`). Scheduled points are
  `<id>-fushi-scheduled/backup.zip` (same zip format as a manual export; entries native-deflated up to
  512 MB each, larger ones stored; entries over 16 MB deflate into a temp file, so memory stays bounded)
  plus meta `categories`, `excludedCategories`, `srsMedia`, `fullDatabase`. A pre-operation point holds
  `fushi.db` (`VACUUM INTO` on a separate read-only connection while the app is running) and, when the
  review DB is open, `srs4.db` (kernel `snapshotInto`); `RestorePointRollbackPlan.database` picks which
  file of a point to swap. Points being written are registered in-process so a concurrent `prune` never
  deletes them. A desktop custom folder is just another store root (scheduled points only).
- **Full database, pick files (user decision 2026-11-25, after review).** Every scheduled point is
  `createBackup(fullDatabase: true)`: the zip's `fushi.db` is the whole DB with no category row stripping
  (library rows of every media kind, progress, statistics, settings, profiles, music, collections, search
  history) plus review notes / history. Only the credential / device-local strip stays (the overwrite
  import re-applies those from this device, as before). The settings checklist only picks file trees
  (`kBackupFileCategories`: dictionary, books, audiobooks, videos, local audio, fonts, game covers) plus the
  review-media switch (D2); default = fonts only, review media off. Old stored category lists drop data
  categories on read. `BackupMeta.fullDatabase` marks the zip; its `excludedCategories` then lists only the
  file categories whose files are not in the zip. Manual export (`fullDatabase: false`) is unchanged.
- **Replace from a full-database point** (overwrite import, `importSettings: true`) is driven by that marker,
  not by guesses: the whole DB is swapped in, no category strip runs (books / videos / audiobooks / games /
  music / progress / statistics rows all stay), data categories restore regardless of the selection; only
  file trees the zip carries are replaced. Trees the zip does not carry, and this device's files, are left
  untouched. Registries that describe files on disk follow the files: dictionary rows (BUG-454 path),
  font catalog and local-audio list are re-seated from this device when their files were not restored.
  Same device, so path rebasing is a no-op (tested). The import confirm dialog / ctl preset only offer file
  toggles for such a zip in overwrite mode. Fill in missing runs on the extracted full DB unchanged.
- **Retention** is one pure function, `planBackupRetention` (`fushi_core/lib/src/utils/backup_retention.dart`),
  shared with the Lapis template backups (`keepMinimum: 10, keepAllWithin: 90 days`, unchanged behaviour).
  Scheduled: newest always kept, 48 h all, then newest per age-bucket day (7), week (4), month (30-day
  buckets, 3), then a 5 GB cap trimming oldest first; the point just written is protected. Every kept
  point claims its buckets; `pruneScheduled` also removes half-written scheduled dirs in its own root (the
  custom folder is not covered by `prune`). Pre-operation: newest 5 **per reason** (so sync-compare runs
  never push out the Anki-migration point, D6). `createPreOperationPoint(protectIds:)` and
  `RestorePointStore.hold(dir)` keep the Replace / Fill target out of every prune while it is restored.
  Pre-update / pre-rollback: unchanged (3 each).
- **Review library not upgraded yet.** While `srs4.db` is not ready (the generation-4 upgrade is still pending,
  running in another process, failed, or only the sealed old library is left), opening it throws. A scheduled
  point then backs up everything else and lists `srs` under `excludedCategories` (restore keeps this device's
  review data, which still sits untouched in its own old file); the status keeps `missingData: ["srs"]` and the
  settings section says why. Pre-operation points carry only `fushi.db` in that state. (Found in the real-app
  check on a seeded pre-upgrade profile: before this, every scheduled run failed.) Manual export has the same
  pre-existing limitation and is unchanged.
- **Schedule** (`fushi/lib/src/sync/auto_backup/`): due rule in `auto_backup_schedule.dart`. With a
  preferred time T and interval N: due when the last *satisfied* run (success, or skipped because nothing
  changed) is before `latestSlot(T) - (N-1) days`; without T the slot is local midnight, i.e. calendar days
  (daily = first launch / resume of each day; a strict `>= N x 24 h` rule would skip every other day for
  someone who opens the app a little earlier each day). A last-satisfied time in the future (clock moved
  back) is due once. The overdue warning also uses "last satisfied" (a skipped run means the newest point
  is still current). Checks: first idle task after the home page is up (`AppModel.startUpdateChecks`),
  app resume, and every 15 min on desktop. Status (`restore_points/auto_backup_status.json`, a file so it
  survives a DB replace) keeps the last result, error and a size+mtime fingerprint of the DB files, the
  ticked file trees and the store root. "Skipped, no changes" needs the same fingerprint **and** the last
  successful point still present in the current store (deleted on the page / ctl undo, or another
  folder, means a new point).
- **Locking.** The export lock is owner-token based (`beginBackupExport()` returns a token,
  `endBackupExport(token)` only releases its own). An auto backup takes it on entering `_run`, before
  the fingerprint. Backup import, Replace and Fill check the lock and take `AppModel.beginRestoreFlow()`
  in the same synchronous step; while a restore flow, an import phase or a data-root migration is active
  (or the DB is not initialised) the auto backup returns busy instead of running against a closed DB.
- **Interrupted runs.** The status gets a `runningSinceMs` marker when a point starts. If it is still
  there on the next `start()`, the run is recorded as failed (`interrupted`), the one-time notice shows,
  half-written dirs are cleaned, and the due rule waits for the next slot (no tight kill loop). A custom
  folder that does not exist (unmounted drive) fails with "folder unavailable" instead of being created.
- **Review media (D2)** is split by `createBackup(includeSrsMedia:)`, not by a new category: a backup
  without `srs_media/` entries leaves the local media tree untouched on replace.
- **Forced points**: before Replace on the Restore points page / ctl (abort if the point fails), before
  applying a sync-compare plan that contains "use remote" (the only flow that overwrites local data from
  cloud / Interconnect; plain sync is merge-only), and before the Anki migration
  (`runSrsAnkiMigration(beforeImport:)`). For the last two a failed point is reported and the operation
  continues. Overwrite-import snapshot and DB-check backups stay as they were and are listed.
- **Restore points page** replaces "Recover library" (same route, orphan-folder recovery kept below the
  list). Fill in missing works for any raw main-DB copy and for the DB extracted from a scheduled zip
  (an unzip failure is shown, the app stays usable). Replace: raw-DB points use the phase-1 swap (current
  DBs become `pre_rollback` points), scheduled zips use the overwrite import. The Replace panel of a
  full-database point says everything comes back and lists the file categories that stay as they are on
  this device; the old "removed from your data" line only shows for scheduled points from before this
  change. Legacy copies (pre-overwrite, DB check) offer Fill in / Export / Delete but not Replace (the
  rollback journal addresses store ids).
- **ctl**: `GET /api/admin/restore-points`, `GET /api/admin/auto-backup/status`,
  `POST /api/admin/auto-backup/run` (undo deletes the point; busy = 409),
  `POST /api/admin/restore-points/restore` (`mode` fill / replace, needs `confirm: true`; replace takes the
  pre-operation point synchronously via `prepareRestorePointReplace`). Op ids `backup.restore-point.list` /
  `.restore`, `backup.auto.status` / `.run`; CLI `fushi ctl backup points` / `point-restore <id> --fill|--replace --yes`
  / `auto` / `auto-run`.
- **Left for phase 3:** macOS security-scoped bookmark for the custom folder (stored as a plain path now;
  phase 3 found it is not needed, see below);
  the non-en/zh translations of the renamed `restore_points_fill_*` keys still say "snapshot"; an exported
  full-database point imported on another device brings library rows whose files were not packed (they show
  as missing there).

## Design: three layers

### Layer 1: snapshot before every migration (phase 1)

- **Restore point store** lives in `fushi_core` (pure Dart, so `fushi_server` gets it too):
  `<db dir>/restore_points/<id>/` with a `restore_point.json` meta file. One directory per point.
  Layer 2 reuses the same store.
- **Main DB.** In `_openDb` (main process only, never `_openDbFile`, never in-memory), before
  `_openWithRecovery`: read `PRAGMA user_version` on a raw connection. If
  `kMinSupportedSchemaVersion <= v < kFushiDbSchemaVersion`, write `VACUUM INTO` the point directory
  (consistent, includes WAL pages; a plain file copy would not), then `PRAGMA quick_check` the copy and
  write the meta last (a point without meta is incomplete and is cleaned up).
- **Review DB (`srs4.db`).** Rust takes its own snapshot inside the gen4 migration once it knows an
  upgrade is needed, into `<dir of srs4.db>/restore_points/<id>/` with the same meta format. Dart passes
  nothing new; Rust owns it (Rust fat-core rule).
- **Never blocks startup.** A failed snapshot (disk full, I/O error) deletes the partial copy, records
  the failure in `restore_points/last_snapshot_status.json` and lets the migration go on. The app shows
  the failure once after startup.
- **Retention:** newest 3 pre-update points per database. Not deleted after a successful migration
  (Kavita deletes them, which is exactly when a rollback needs them).
- **Rollback.** The downgrade screen and the unrecoverable-DB screen offer "Restore data from before the
  update" when a compatible point exists (schema <= this build's). The swap runs offline (DB not open):
  the current DB moves into a new `pre_rollback` point (so the rollback can itself be undone), the
  snapshot is copied in, and the app restarts. Crash safety follows the sidecar pattern of
  `recoverPendingRestore`. The review DB is rolled back together when it is also newer than this build.
- Trigger is the schema check, not the updater, so it covers App Store / TestFlight, manual Inno / APK
  installs and Linux packages as well as the in-app updater.

### Layer 2: scheduled backups (phase 2)

- Engine: `BackupService.createBackup` headless, written into the restore point store as a `scheduled`
  point. DB entries compressed (manual export stores them uncompressed).
- Settings section "Automatic backup" under Sync & backup:
  - interval: Off / Daily (default) / Every 3 days / Weekly;
  - preferred time (optional, e.g. at night). On desktop it runs at that time while Fushi is open;
    otherwise (and on mobile, where the app cannot run on a schedule) it catches up on the next launch
    or resume;
  - contents: the same category checklist as manual export, pre-filled with the default set;
  - folder: default restore point store; optional user folder (desktop picker, Android SAF tree, iOS
    folder visible in Files). Warns that the default location goes away on uninstall;
  - status line: "Last backup: 3 h ago · 412 MB · 14 kept"; warning when the last success is older than
    2x the interval or the last run failed.
- Skipped when nothing changed since the last backup.
- Forced backups (ignore the interval): before overwrite import, DB repair, a full download that
  overwrites from cloud / Interconnect, the Anki / SRS migration, and before any restore.
- Retention: everything from the last 48 h, then 7 daily, 4 weekly, 3 monthly, and a 5 GB size cap that
  trims the oldest scheduled points first. Pre-update and forced points have their own rules, so routine
  backups never push them out.

### Layer 3: Restore points page (phase 2)

- Grows out of "Recover library". Lists pre-update, scheduled, forced, pre-rollback, pre-overwrite and
  DB-check copies with kind, date, app version, schema, size and contents.
- Actions: **Fill in missing** (existing preview + `fillMissingOnly` merge engine), **Replace**
  (`restoreBackup` path; takes a forced backup first, pauses sync until restart, re-applies the
  device-local layer such as credentials), export to file, delete.
- The Anki-migration notice is re-pointed at this page (key `srs_anki_migrate_setup_notice_restore_point`).

### Phase 3: off-device copies

User folder on Android (SAF) / iOS (Files), optional Android WorkManager run, then cloud upload once the
sync backend gets list / delete for stored archives.

## Phase 3 as implemented (2026-11-25)

- **Local first, then a copy (mobile).** On Android and iOS a scheduled point is still written to the
  local store first (atomic, pruned as before). If the user picked a folder
  (`AutoBackupSettings.mirrorFolder`, device-local prefs `auto_backup_mirror_folder` = handle and
  `auto_backup_mirror_label`), the finished point is copied to `<folder>/<id>/backup.zip` +
  `restore_point.json` (same layout as the store; meta written last = complete marker; an existing meta is
  deleted before files are overwritten, so a re-copy never looks complete half way). Copying does **not** hold
  the export lock (see "Review fixes" below); the local point is `hold`-pinned meanwhile. Desktop is
  unchanged: the phase 2 custom folder is the store root.
- **Shared folders.** A user folder is often a synced folder used by several devices. The folder copy's meta
  carries `deviceId` (sync device id, device-local) and `deviceName` (`resolveInterconnectDeviceName`).
  Folder retention (`planMirrorRetention`) applies the scheduled policy (48 h, 7 daily, 4 weekly, 3 monthly,
  5 GB) to **this device's copies only**; other devices' copies and copies without a device are never
  deleted automatically (the user can delete them on the page). A reinstall gets a new device id, so the old
  install's copies are kept until deleted by hand (safe direction).
- **Status.** `auto_backup_status.json` gains `mirror {target, pointId, atMs, error, errorAtMs, pendingId}`;
  `target` is a 16-hex sha1 of the handle (the bookmark / URI itself is not written there). A copy failure
  does not fail the backup: the local point is the result, the settings row shows a warning and the user is
  told once (`notifyMirrorFailure`). `pendingId` is set while a copy runs; if it is still there on the next
  run, that exact half-written `<id>/` is deleted from the folder (another device's half-written dirs are not
  touched), then the latest point is copied again.
- **When copies happen.** After every new scheduled point ("Back up now" included). On a due run with no
  changes, a latest point that is not yet in the folder is copied (that slot's retry). On a not-due check
  (launch / resume / folder change), a missing copy is caught up silently unless the last copy to that folder
  failed explicitly; failures wait for the next due slot or "Back up now", so a revoked folder does not
  retry and notify on every resume.
- **Android: SAF tree + persisted permission** (`BackupFolderChannel.java`, channel
  `app.fushi.reader/backup_folder`). `ACTION_OPEN_DOCUMENT_TREE` with persistable read/write grant,
  `takePersistableUriPermission`; no all-files access needed. All folder I/O is native (`DocumentsContract`
  / `ContentResolver`, background thread), addressed by display name. If a provider renames a created file
  (suffix), the copy fails instead of writing a name the listing cannot find. A revoked grant / deleted
  folder maps to "folder unavailable". "Stop copying" / choosing another folder releases the old grant.
- **iOS: picked folder + security-scoped bookmark**, reusing the source-folder bookmark channel
  (`FushiDirectoryImport.swift`, `pickDirectoryBookmark` / `startAccessingBookmark` /
  `stopAccessingBookmark`); no new Swift. Chosen over exposing the app's own Documents folder in Files
  (already `UIFileSharingEnabled`): that folder is deleted on uninstall and never leaves the device, which is
  exactly what this phase protects against; a picked folder can live in iCloud Drive or another file provider.
  Access is started for each run and stopped after; a stale bookmark is rebuilt in the access window and
  saved back. iCloud copies whose meta is not downloaded (`.restore_point.json.icloud`) are counted and the
  page says to download them in the Files app.
- **Restore points page.** A "In your backup folder" section lists copies that are not on this device
  (another device's, or ones whose local point was pruned / lost in a reinstall) with "Copy to this device"
  and Delete (inline confirm). "Copy to this device" copies into a staging dir next to the store, checks the
  sizes against the meta, writes the meta and renames the whole dir into the store, so the store never shows
  a half point; afterwards it is an ordinary scheduled point (Fill in / Replace / Export). Local rows that
  also exist in the folder say so; copies from a device show "From <device>". A folder that cannot be opened
  shows the reason in that section only.
- **macOS custom folder.** No bookmark needed: the macOS app is not sandboxed (`Release.entitlements` and
  `DebugProfile.entitlements` drop `com.apple.security.app-sandbox` for in-app updates; no Mac App Store
  build exists). If the sandbox ever returns, the custom folder has to store a bookmark like the data root.
- **Android background run (WorkManager): not done, on purpose.** A scheduled point is
  `BackupService.createBackup` on the open drift DB plus the Rust review kernel (`srsStorageForBackup`),
  credential stripping and the device-local layer; it needs the app's isolate. Running Dart from WorkManager
  means a background `FlutterEngine` with all plugins, which is the structure that BUG-4271 / feedback
  yjn-3h8B-7 removed (audio_service attaches to it, starts a second `main()` engine and binds its static
  handler to the background engine). A native worker cannot build the archive, and a second engine opening
  `fushi.db` / `srs4.db` while the foreground app owns them would need cross-process locking the kernel does
  not have. Mobile keeps "catch up on next launch / resume".
- **Cloud copies:** built after the user's decisions D8–D11, see "Cloud copies as implemented" below. The
  research that led to it is kept as "Cloud copies: proposal".

### Review fixes (2026-11-25, after the phase 3 review)

- **Device scoping everywhere.** Every scheduled point records the writing device (`deviceId` = 16-hex sha1
  of the sync device id, `deviceName`) in its meta and writes an owner marker `.restore_point_owner` into the
  draft dir first (not counted as a point file). `RestorePointStore.pruneScheduled(deviceId:, sharedRoot:)`
  only plans retention over this device's own points: other devices' points and copied-back points take no
  day / week / month bucket, do not count against the 5 GB cap and are never auto-deleted. Copied-back points
  carry `copiedBackAtMs` and are never auto-pruned (the user deletes them on the page). Points without a
  device: own in the private default store, foreign in a desktop custom folder (`sharedRoot`), so two desktops
  sharing a synced folder never prune each other. `cleanIncompleteScheduled` in a shared root only removes
  meta-less dirs whose owner marker is this device (a dir whose meta has not synced yet must not be deleted:
  the deletion would sync back and destroy the other device's point). Phase 2 custom-folder points written
  before this change have no device and are therefore never auto-pruned (phase 2 has not shipped).
- **Copies run outside the export lock.** A committed point is immutable and `hold`-pinned, so the copy
  (including silent catch-up on launch / resume) runs after the lock is released, with its own in-flight
  flag per target. A hung provider no longer leaves restore / replace / manual export "busy" until restart.
  Copy-back and delete on the page use the same per-target flag (busy only when that target already has an
  operation running). Java `runIo` catches `Throwable` and always replies exactly once.
- **Precise half-copy cleanup.** The mirror status keeps `pendingId` (copy in flight / interrupted) and
  `leftovers` (half copies whose cleanup failed). On the next copy to the **same target** these ids are deleted
  only if the listing has no meta for them (a copy killed during prune, after its meta was written, is
  complete and kept). A failed upload deletes its own `<id>/` best effort; if that fails too, the id goes into
  `leftovers`, so meta-less dirs can always be cleaned. An explicit failure still waits for the next slot
  (catch-up skips it), an interruption does not.
- **Pruning is per item.** One undeletable old copy no longer fails the whole copy: the new copy is recorded
  as done, the ids that could not be removed go into `pruneError` (shown as an info line, no toast) and are
  retried next time.
- **Untrusted names.** Copy ids from a folder / provider / cloud must match `isScheduledRestorePointId`
  (`<UTC timestamp>-<db>-scheduled[-n]`, plain name: no `.`, `..`, separators or NUL) when listing, before
  copy-back and before delete; file names in meta use the same plain-name rule.
- **Listing robustness.** iOS / desktop `IoBackupFolderMirror.list` and Android `list` skip an unreadable entry
  instead of failing the whole folder. Android cloud providers that report `EXTRA_LOADING` are re-queried
  (up to about 3 s) and otherwise fail with `copy_loading` instead of returning a partial list (which would
  have created duplicate dirs).
- **Error codes instead of raw text.** Native codes `UNAVAILABLE` / `NOT_FOUND` / `LOCAL_IO` / `UNSUPPORTED` /
  `RENAMED` / `LOADING` / `INVALID_ARG` / `IO_FAILED` / `INTERNAL` map to status codes (`folder_unavailable`,
  `copy_not_found`, `copy_local_io`, `copy_unsupported`, `copy_renamed`, `copy_loading`, `copy_failed`) with
  localized text; raw platform messages (URIs, paths, server bodies) only go to the debug log. Directory
  creation checks the provider's display name like files do (`RENAMED`), and a failed delete of the old meta
  fails the copy. A rebuilt iOS bookmark is saved from every folder session (copy, list, copy-back, delete).

### Second review fixes (2026-11-25)

- **Cloud namespace is reserved.** The cloud folder is `__backups__` (was `fushi-backups`), so
  `isReservedSyncNamespaceName` covers it: the sync compare dialog and the cloud bookshelf no longer list it
  as a remote book, "Delete remote" cannot wipe every device's cloud copies (BUG-5007 shape), and the
  Interconnect host's file-box prune skips it. Nothing had shipped, so no migration. The guard
  `interconnect_file_box_prune_reserved_guard_test.dart` names it explicitly.
- **Shared root, unknown device.** `cleanIncompleteScheduled(sharedRoot: true)` with no device id (identity
  lookup threw) deletes nothing: "no owner marker" and "my id is null" are no longer treated as the same owner.
- **Private store ignores device marks.** In the private default store only `copiedBackAtMs` excludes a point
  from pruning (another device's point can only get there through copy-back, which sets it). Points written
  under an old sync device id (data cleared, database swapped) are pruned again. The shared-root rule is
  unchanged (own marked points only, none when the id is unknown).
- **Unreadable is not half-written.** `MirrorFolderListing.unreadable` lists ids whose dir exists but whose
  meta could not be read this time (dart:io read error, iCloud placeholder, malformed meta, cloud per-copy
  error, Android `IOException` / unreadable stream, reported by the channel as `{name, unreadable: true}`).
  Pending / leftover cleanup skips them and keeps them in `leftovers` for the next copy; only ids with
  definitely no meta are deleted. If this device's own cloud folder cannot be listed, the whole listing fails
  instead of hiding all own copies.
- **Target claimed before the first await.** `_mirrorEverywhere` claims a target (`_mirroring`) right after
  the status checks and before awaiting `networkUnmetered()`, and releases it in `finally`, so two catch-ups
  (resume + desktop timer) cannot copy to the same target at once. Closing a target (iOS
  `stopAccessingBookmark`) is best effort everywhere (copy, list, copy-back, delete): a close error is logged,
  never replaces the action's result or error and never leaves the target "busy".
- **Cloud sign-in failures are visible.** `cloudTarget()` returns null only when no supported backend is
  configured (the settings row already shows a setup hint). Configured but `restoreAuth` false / throwing now
  throws a coded `BackupMirrorException` (`cloud_auth`, `cloud_unreachable`, ...); the controller records it
  in `status.cloud` (keeping the last target and leftovers) and toasts once on the scheduled run; catch-ups
  stay quiet and do not rewrite the same error. Errors the host did not classify become `cloud_failed`;
  `listCloudCopies` and page actions go through the same mapping, so raw messages never reach the error log.
- **Status key per account.** The cloud target key is `cloud-<type>-<12-hex sha1 of type|identity>`
  (`cloudBackupTargetKey`): Drive / Dropbox account email, WebDAV URL + user, FTP / SFTP host + port + user,
  Interconnect host certificate fingerprint (URL if none). Switching accounts no longer skips the new account
  or lets the old account's failure block catch-up. The raw identity is never written or logged; when it is
  unknown (email fetch failed) the key falls back to `cloud-<type>`, which costs one extra listing later.
- **Error classes.** Rate limits (Drive "Quota exceeded for quota metric" / `rateLimitExceeded`, HTTP 429,
  Dropbox `too_many_*`) map to `cloud_unreachable` (retry later); only storage full (`storageQuotaExceeded`,
  `insufficient_space`, 507, FTP 552, other "quota") maps to `cloud_quota` (`classifyCloudBackupErrorText`).
- **Dropbox sessions.** The `incorrect_offset` resync cap (8) counts per chunk and resets when a chunk is
  accepted; `finish` has its own cap. `too_many_write_operations` is transient both at the top level and
  nested under `path` in finish errors.
- **Nits.** Android `networkUnmetered` answers inline on the main thread instead of queueing behind a long SAF
  copy on the serial I/O executor. `isPlainRestorePointFileName` also rejects `:` (NTFS alternate data
  streams).

### Cloud copies as implemented (D8–D11)

- **One more mirror target.** `SyncAssetStoreBackupMirror` (`sync/auto_backup/cloud_backup_mirror.dart`)
  implements the same `BackupFolderMirror` on top of `SyncAssetStore` only; the controller treats the user
  folder and the cloud as two `AutoBackupMirrorTarget`s with separate status (`mirror` / `cloud` in
  `auto_backup_status.json`), so meta-last completion, pending / leftover cleanup, device-scoped retention,
  catch-up and "Copy to this device" are shared. Each target copies independently; neither holds the export lock.
- **Backend.** The first enabled sync channel (cloud before Interconnect) whose type is Google Drive,
  Interconnect (`fushiServer`), Dropbox, WebDAV, FTP or SFTP; OneDrive is not offered (D9). It must be signed in
  (`restoreAuth`); if it is configured but cannot sign in, the failure is recorded and shown (see "Second
  review fixes"). Every backend call runs under the sync channel's resource lock (`syncResourceLocks`, same as
  sync: the backends are process-wide singletons) and idempotent calls (list, read, mkdir, delete) go through
  `retryTransientSync`; uploads are not retried in place: a failed upload deletes its half copy and the next
  slot retries (WebDAV / FTP / SFTP / Interconnect cannot resume). Dropbox uploads over 128 MiB now use upload
  sessions (8 MiB chunks, `incorrect_offset` resync capped per chunk, transient retry with `Retry-After`
  including `too_many_write_operations`, one token refresh).
  Drive keeps its resumable 8 MiB chunks.
- **Where files land.** Under the backend's existing sync root and scope (no new OAuth scope):
  `fushi-data/__backups__/<device key>/<point id>/backup.zip` + `restore_point.json` (`__backups__` is a
  reserved sync namespace, never listed as a remote book).
  Google Drive: the hidden `appDataFolder` (counts against the user's quota, not visible in Drive).
  Dropbox: the app folder, `/Apps/<app>/fushi-data/__backups__/...`. WebDAV / FTP / SFTP: `fushi-data/` under
  the configured base path / login directory. Interconnect: on the host, `<host data dir>/fushi-data/__backups__/...`
  (the app host's database directory, or `paths.syncData` for the headless server); the host's own Restore
  points page does not list them. The zip goes through `putAsset`, so on cloud backends it is stored with the
  sync layer's content obfuscation (only Fushi can turn it back into a zip); the meta goes through
  `putBytesAsset` (plain JSON).
- **Listing.** All device folders are listed (another device can copy back), each copy's meta is read and
  validated; FTP's missing sizes / mtimes do not matter (retention reads the meta). FTP's delete-missing throws:
  deletes only target dirs found in a fresh listing. Auth / unreachable errors and an unlistable own device
  folder fail the whole listing; other per-copy errors skip that copy and report it as unreadable.
- **Errors.** Backend exceptions become codes (`cloud_auth`, `cloud_unreachable`, `cloud_quota`, `cloud_failed`);
  messages (which can carry server URLs or response bodies) never reach status, toast or logs (the log gets
  the exception type only). Rate limits count as unreachable, only a full store as quota. Credentials are never
  in meta or status; the status target key is `cloud-<backend type>-<hash of the account / server identity>`.
- **Network (D10).** Default Wi-Fi only (`auto_backup_cloud_metered` off). Android asks
  `ConnectivityManager.isActiveNetworkMetered()` (new channel method `networkUnmetered`; a metered Wi-Fi
  hotspot counts as metered); iOS treats a routable IPv4 address on `en0` as Wi-Fi (no Swift change); desktop
  is always unmetered. The app had no connectivity helper (no `connectivity_plus`), hence
  `currentNetworkUnmetered`. On a metered network the copy is skipped without an error and caught up on the next
  check (resume / launch / desktop timer).
- **Retention (D11).** `kCloudBackupRetention`: newest always, 7 daily + 4 weekly, plus the 5 GB cap as a quota
  guard; this device's copies only.
- **Settings.** Under Automatic backup: "Copy to cloud" switch naming the service (disabled with a setup hint
  when no listed backend is configured), a fewer-copies hint, "Also upload on mobile data" (Android / iOS only),
  and a status line (uploaded / pending / waiting for Wi-Fi / failed reason), plus the prune info line. Prefs
  `auto_backup_cloud` / `auto_backup_cloud_metered` are device-local.
- **Restore points page.** An "In the cloud" section like the folder one (cloud-only copies, Copy to this
  device, Delete, "From <device>"); local rows say "Also in the cloud".
- **Tests.** Fake `SyncAssetStore` (`FakeAssetStore`, no sizes like FTP) for the mirror and the controller;
  there is no test backend configured for automated tests, so no real-backend smoke test.

### Cloud copies: proposal (research before D8–D11)

Findings: the spec's premise is stale. Every sync backend already implements `SyncAssetStore`
(`packages/fushi_engine/lib/sync/sync_asset_store.dart`) with `putAsset` (streaming), `listChildren`,
`getAsset` and `deleteAsset`: Google Drive (resumable 8 MiB chunks), OneDrive (upload session over 10 MiB),
Dropbox (single `files/upload` request, no upload session), WebDAV, FTP, SFTP and Interconnect (single PUT, no
resume). Caveats: FTP lists no sizes and mtimes only up to 50 files and its delete throws on a missing file;
Interconnect lists no size; Drive's default space is the hidden `appDataFolder` (counts against the user's
quota, invisible outside the app).

| Option | What | Cost | Risk |
|---|---|---|---|
| A. Sync backend as a second mirror target | `SyncAssetStoreBackupMirror implements BackupFolderMirror` under `fushi-backups/<deviceId>/<id>/` (built as the reserved `__backups__`); the controller's copy-after-local, device-scoped retention, catch-up and page "Copy to this device" are reused unchanged. Retention reads the meta json, never backend mtimes. | ~2 days + Dropbox upload sessions (~1 day) + settings UI | Quota on daily full-DB zips; mobile data; large single-PUT uploads restart from zero on WebDAV/FTP/SFTP/Interconnect; iOS suspends long uploads in the background. |
| B. User folder inside a cloud provider (done) | Pick an iCloud Drive / Nextcloud / Syncthing folder | 0 | Android Google Drive app does not offer folder trees; iCloud eviction needs a manual download. |
| C. Interconnect push to the paired desktop | Same as A, restricted to the Interconnect backend, host stores under its sync data dir | ~1 day on top of A | Only when the desktop is reachable. |

Recommendation: keep B as the shipped path; build A next as one more `BackupFolderMirror`, enabled first for
the resumable backends (Google Drive, OneDrive) plus Interconnect, with Dropbox after upload sessions land.
Needs user decisions first (decision board): which backends; Wi-Fi-only default; Drive hidden vs visible
space; a smaller cloud retention (e.g. 7 daily) to save quota.

### Phase 3 open questions

1. ~~Copied-back points pruned by the next run~~: fixed, copied-back points are never auto-pruned.
2. ~~Desktop custom folder without device scoping~~: fixed, see "Review fixes".
3. iCloud-evicted copies only get a notice; `FileManager.startDownloadingUbiquitousItem` could fetch them
   (new Swift, not buildable or testable on the Windows dev box).
4. ctl / CLI do not list or copy folder copies (`GET /api/admin/restore-points` is local only).
5. iOS: a long copy to the folder is suspended when the app goes to the background; it is caught up on the next
   launch (`pendingId`). `beginBackgroundTask` would add about 30 s.
6. Real-device checks of the SAF / iCloud flows were not done (the debug build has no separate
   applicationId, so installing it would overwrite the user's app).
7. iOS "unmetered" is a heuristic (routable IPv4 on `en0`); a personal-hotspot or "Low Data Mode" Wi-Fi counts
   as unmetered. `NWPathMonitor` (`isExpensive` / `isConstrained`) needs Swift that cannot be built here.
8. Dropbox: a `finish` response lost after the server committed can make a successful upload count as failed
   (the copy is deleted and redone in the next slot; it is never half-visible).
9. Cloud upload happens before pruning, so a nearly full store can fail the upload that pruning would have
   made room for; the failure shows `cloud_quota` and the user can delete old cloud copies on the page.

## Decisions (taken by the user 2026-11-25 on the proposal's recommendations; maintainer may change)

| # | Question | Options | Chosen |
|---|---|---|---|
| D1 | Scheduled backups on by default? | on / off | **On, daily, whole database + small file set (fonts).** Layer 1 is always on, no setting. *Revised by the user 2026-11-25 after review: "Full DB, pick files" (was: small category set, which stripped library rows).* |
| D2 | Review media (card images / audio) in scheduled backups? | include / exclude / incremental by hash | **Notes + history included; media off by default with a switch.** |
| D3 | Retention | flat keep-N / tiered / age-based | **Tiered: 48 h all, 7 daily, 4 weekly, 3 monthly, 5 GB cap. Pre-update: newest 3 per DB.** |
| D4 | Off-device copies via cloud backend | now / later | **Later (phase 3).** User folder first. |
| D5 | Downgrade-screen rollback | replace with newest compatible snapshot / reverse-migrate ("Downgrade & Quit") | **Replace**, keep the newer DB as a `pre_rollback` point, state what is lost. |
| D6 | Misleading Anki-migration text | fix now separately / re-point with phase 2 | **Re-point at the Restore points page in phase 2** (forced backup before the migration makes it true again). |
| D7 | What to back up / when | fixed / user choice | **User choice:** file-tree checklist (books, audiobooks, videos, dictionaries, fonts, local audio, game covers) + review-media switch + interval + optional preferred time; library, progress, statistics, settings and review notes are always included. *Revised by the user 2026-11-25 after review (was: the full category checklist).* |
| D8 | Cloud copies: when | later / now, same batch | **Now, same batch** (same branch, separate commits). Replaces D4's "later". |
| D9 | Which backends | resumable only (Drive, OneDrive) + Interconnect / all with list+delete / pick a set | **Google Drive, Interconnect, Dropbox, WebDAV, FTP, SFTP; not OneDrive.** Dropbox gets upload sessions; backends that cannot resume clean up a failed upload and retry next slot. |
| D10 | Mobile data | Wi-Fi only by default / any network / ask | **Wi-Fi only by default**, a setting allows mobile data; desktop / ethernet counts as unmetered. |
| D11 | Cloud retention | same as local / fewer | **Fewer: 7 daily + 4 weekly**, this device's copies only (implementation adds the 5 GB cap as a quota guard). |

## 决策摘要（中文）

用户 2026-11-25 按提案建议拍板，维护者可改：D1 定时备份默认开、每日，每份都是整库、文件只默认带字体（更新前快照常开、无开关；
审查后用户 2026-11-25 改为「整库 + 挑文件」，原为按类别的小集合、会剥掉书库行）；
D2 复习笔记与记录进备份，卡片媒体默认不进、可开；D3 分层保留（48 小时全留、7 日 4 周 3 月、5 GB 上限），
更新前快照每库留最近 3 份；D4 云端异地副本放第三期；D5 降级屏回滚 = 换回最新兼容快照、当前库另存为
`pre_rollback` 还原点；D6 Anki 迁移提示随第二期改指向还原点页；D7 频率与偏好时间由用户选，内容只挑带哪些大文件
（书、有声书、视频、词典、字体、本地音频、游戏封面）与复习媒体开关，书库、进度、统计、设置与复习笔记每次都在（同日审查后
用户改定，原为完整类别勾选）。从整库定时点「替换」：整库换回，包里带着的文件换回，没带的文件在本机原样不动、书库条目照样保留。
D8–D11（用户 2026-11-25 拍板）：云端副本这一批就做（同分支、分开提交）；后端为 Google Drive、互联、Dropbox、WebDAV、FTP、SFTP，
不含 OneDrive，Dropbox 补上传会话，不能续传的后端失败就清掉半截、下个时段重来；默认只在 Wi-Fi 上传，可开「也用移动数据」，桌面 / 有线
算不计流量；云端保留更少：7 日 + 4 周（只动本机写的副本，另有 5 GB 上限防配额被占满）。同批按审查修好：定时点都记写入设备，本机 /
自定义文件夹 / 云端都只修剪本机写的，取回本机的点不自动删；复制不再拿导出锁；半截副本按目标与元数据精确清理；修剪逐份尽力。

## Naming

New code uses `restore_point*` / `auto_backup*`. `srs_sync_v1_removed_guard_test` bans the removed
SRS backup names (`srs_backup_store`, `srs_backup_retention`, `srs_point_in_time_restore`, ...).
