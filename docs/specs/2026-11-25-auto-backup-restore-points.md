# Auto backup and update rollback (restore points)

Status: phase 1 implemented (branch `feat/auto-backup-p1-update-snapshot`), phase 2 implemented (branch
`feat/auto-backup-p2-scheduled`, stacked on phase 1), phase 3 user folder on mobile implemented (branch
`feat/auto-backup-p3-offdevice`, stacked on phase 2); cloud copies are a proposal only. Owner: auto-backup session. Proposal with the comparison of other apps:
https://claude.ai/artifact/GzX9ynemY4FxoXn85dbvCp (private; summary below so this file stands alone).
Phase 4B (the server backs itself up) implemented on branch `feat/auto-backup-p4b-server-self`, stacked on
phase 3; see "Phase 4B as implemented".

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
- **Backend.** (Phase 4A: Interconnect is no longer a cloud backend, see D12.) The first enabled sync channel (cloud before Interconnect) whose type is Google Drive,
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

## Phase 4A as implemented: devices back up to the server (2026-11-25, D12–D13)

- **Own target.** `AutoBackupMirrorKind.server` is a third `AutoBackupMirrorTarget` next to folder and cloud,
  with its own status (`server` in `auto_backup_status.json`), so meta-last completion, pending / leftover /
  unreadable handling, claim-before-await, catch-up, notify-once and "Copy to this device" are the same code
  (the controller's cloud-only branches became `kind.remote`: `_remoteTarget`, `_recordUnavailable`). The cloud
  target no longer picks Interconnect (`_cloudBackupBackends` lost `fushiServer`): Google Drive, Dropbox,
  WebDAV, FTP, SFTP only. A device can copy to a cloud service and to its server at the same time.
- **Which server.** The Interconnect channel that sync itself uses: the `isInterconnect` entry of
  `enabledSyncChannelBackends` (Interconnect switch on, or the backup backend set to Interconnect). The
  Interconnect backend is a process-wide singleton over the paired candidate addresses; whichever host it
  connects to is the one sync uses. Every call runs under that channel's resource lock, idempotent calls go
  through `retryTransientSync`, errors map to the same codes as the cloud (`cloud_auth`, `cloud_unreachable`,
  `cloud_failed`, ...; texts talk about "the sync service / server"). Status key
  `server-<12-hex sha1 of the host identity>` (`serverBackupTargetKey`; identity =
  `connectedHostIdentity()`: the paired hostId, else the address). Label: the paired device name of that host
  (else the first enabled address with a name, else "Fushi Interconnect").
- **Layout on the host.** Same as the cloud: `fushi-data/__backups__/<device key>/<id>/backup.zip +
  restore_point.json`, written through the host's generic WebDAV handler. On the headless server that is
  `<data dir>/interconnect/sync-data/fushi-data/__backups__/` (`FushiSyncServer.syncDataDir` is
  `paths.syncData/sync-data`; the phase-3 text "`paths.syncData`" was one level short). Interconnect is not
  wrapped in `ObfuscatingSyncBackend`, so the stored zip is a plain Fushi backup zip.
- **Retention (D13).** `kServerBackupRetention` = the local / folder policy (48 h all, 7 daily, 4 weekly,
  3 monthly, 5 GB), own copies only; other devices' and copied-back copies are never auto-deleted. The server
  never deletes device copies by itself.
- **Network.** One "Also upload on mobile data" switch covers cloud and server (pref key
  `auto_backup_cloud_metered` kept, frozen name). It moved out of the cloud row into its own row
  `sync.auto_backup.metered`, shown on Android / iOS when automatic backup is on and cloud or server copies are
  on. Chosen over a per-target switch because "may Fushi use mobile data for backups" is one question for the
  user; two identical switches would read as a bug.
- **Settings.** "Copy to server" (`sync.auto_backup.server`, pref `auto_backup_server`, device-local, off by
  default): subtitle names the server; disabled with "Set up a Fushi Interconnect server in sync settings
  first" when there is no Interconnect channel; when on, the retention hint and a status line (copied /
  pending / waiting for Wi-Fi / failed reason) plus the prune-failed line. The cloud "no backend" hint no
  longer lists Interconnect (new key `auto_backup_cloud_no_service`).
- **Restore points page.** An "On the server" section (server-only copies, Copy to this device, Delete with
  server wording, "From <device>"); local rows say "Also on the server". ctl `auto-backup` status carries
  `serverCopies` / `serverCopy`.
- **Disk layer (fushi_core).** `DeviceBackupInbox` (`database/device_backup_inbox.dart`) lists, finds, returns
  the zip of, and deletes received copies under a sync root. Every name from the network or a request is
  validated before touching disk: device keys `isDeviceBackupKey` (1–64 lowercase hex), ids
  `isScheduledRestorePointId`, joined paths must stay inside the inbox, links / junctions are not followed,
  a copy counts only if its meta parses as a scheduled point and every file it lists exists. The namespace
  constant lives there (`kDeviceBackupsNamespace`; the app's `kCloudBackupNamespace` points at it).
- **Headless server.** `GET /api/admin/device-backups` (devices grouped: name from the newest meta, copy count,
  total bytes incl. incomplete dirs, newest date, incomplete count, copies with date / size / schema / app
  version), `GET .../<device>/<id>` (streams the zip, `fushi-<name>-<id>.zip`), `DELETE .../<device>/<id>` and
  `DELETE .../<device>`; bad names → 400 without echoing them, missing → 404
  (`packages/fushi_server/lib/src/admin/admin_device_backups.dart`, one hook in `admin_api.dart`). Not in the
  remote AI op directory (contains whole databases; test asserts it). WebUI page "Device backups" in its own
  file (`web_ui_device_backups.dart`, hooked into `web_ui.dart` / `web_ui_en.dart` by const concatenation /
  spread): per device and per copy, Download, Delete, Delete all, and notes on the device-side trimming rules
  and how to restore (Import backup in Fushi, or Restore points › On the server on the device).
  `fushi_server ctl device-backups [ls]`, `device-backups rm <key> <id>`, `device-backups rm <key> --yes`.
- **Tests.** fushi_core `device_backup_inbox_test.dart` (grouping, incomplete, zip, delete, name validation,
  planted link); server `admin_device_backups_test.dart`, `ctl_device_backup_commands_test.dart`,
  `web_ui_i18n_test.dart`; app controller group "服务器副本（第四期 D12–D13）" (independent of cloud, status
  round trip, off → null, local retention on the server, unreachable → status + one toast, unclassified error
  → `cloud_failed` without the raw text, shared metered rule, copy back / delete), settings section (order,
  metered-row rule, pref round trip / device-local registration, server row states, status line), page section
  (list, "Also on the server", delete, copy back). The Sync & backup golden viewport grew to 4700 / 7800 px.
  Real check: `fushi_server` from source with a temp config / data dir, fake copies on disk, admin API list /
  download (bytes identical) / bad names / delete, ctl list.

### Phase 4 review fixes (2026-11-25, third review)

- **Remote copy on, but no service** (4A). Interconnect stopped being a cloud backend, so "Copy to cloud" on
  with only Interconnect configured used to copy nothing and say nothing (`cloudTarget()` → null, nothing
  recorded). `_resolveTargets` now records `cloud_no_service` / `server_no_server` in that target's status when
  the switch is on and the host returns no target; the settings status line shows "failed: Set up … first"
  (the existing no-backend hint texts `auto_backup_cloud_no_service` / `auto_backup_server_no_server`, no new
  keys). Notified once: the same no-service reason already recorded is not notified again on later slots or
  "Back up now". User switches are never flipped. Page actions with no target throw the same codes (was
  `cloud_auth`).
- **Per-device scope on cloud / server** (4A). `BackupFolderMirror.delete(id)` is now "this device's `<id>/`":
  `SyncAssetStoreBackupMirror` only looks in its own device folder (it used to delete the first match across
  all device folders, so two devices that wrote the same millisecond id could delete each other's copy). New
  `deleteCopy(copy)` deletes exactly the listed copy (its directory asset id); the Restore points page and
  retention pruning use it. `MirroredRestorePoint.inOwnSlot` (false for copies in other device folders; always
  true in flat user folders, where an id has one location) keeps another device's same-id copy out of the
  controller's "complete / already uploaded" set used for half-written cleanup and the upload skip.
- **Server label** uses the host identity of the resolved Interconnect session
  (`InterconnectSyncBackend.resolvedHostIdentity`, no probing), the same identity the target key and label use;
  unresolved sessions still fall back to the first named enabled address.
- **ctl `device-backups`** strips control / bidi characters from device-controlled text (name, id, version)
  before printing.
- **Restore keeps documents and the device inbox** (4B): see "Restore keeps what is not old data" below.
- **Automatic run never escapes as an unhandled error** (4B): the fingerprint is computed inside the try that
  records `lastFailure`; `_track` catches anything a job body lets through and completes with a failed result
  (the admin API's "Run now" never listens to `done`, and fushi_server has no guarded zone, so an escaped error
  could take the process down). The data-dir walk (`serverBackupWalkFiles`) skips directories that vanish
  mid-walk and still fails, with a recorded failure, on real permission errors.
- **Nits.** Admin API maps `disabled` / `notDue` refusals to `automatic_backup_disabled` /
  `automatic_backup_not_due` (were reported as "backup in progress"); top-level / inbox path parts are compared
  case-insensitively on Windows and macOS.

### Phase 4A open questions

1. **App as Interconnect host has no inbox UI.** *Closed in phase 5 (D17), see "Phase 5 as implemented".*
   Phones paired to a desktop app host copy their backups into
   its `sync-data/fushi-data/__backups__/`, so the desktop's inbox fills up, but the desktop has no list or
   delete for it (only the devices trim their own copies; nothing caps the total). `DeviceBackupInbox` is ready
   for a "Received from other devices" section on the Restore points page (list + delete; the app host's sync
   data dir comes from `FushiServerController`'s `syncDataDir`); not built in this batch.
2. **Per-device write scope on the host.** Interconnect auth scopes requests to paired devices, but any paired
   device can write or delete under any `__backups__/<device key>/` over WebDAV (the device-side page may
   delete another device's copy by design, as in the cloud). A host-side rule "a device may only write its own
   key" would need the host to know each peer's device key.
3. **No size cap on the host.** The host accepts whatever devices upload; each device trims its own copies
   (5 GB cap per device), and the admin can delete copies. A server-wide quota for received backups is not
   implemented.
4. **Real device → server run** (phone copying over Interconnect to a running server, then restoring from the
   server section) was not done: the app was not launched in this batch; the server side was checked with
   copies placed on disk.
5. WebUI "Device backups" page was not looked at in a real browser (markup and script are tested, and the page
   script parses with `node --check`).

## Phase 4B as implemented (2026-11-25): the server backs itself up

Built next to 4A and merged into the same branch (`feat/auto-backup-p4-server`). Phase 4 was chosen by the user
on 2026-11-25 as "both devices → server (4A) and server self-backup (4B)"; D14–D16 below are the recommended
defaults, maintainer may change. Everything lives in `packages/fushi_server/lib/src/backup/`.

- **One job lock for all server backups.** `ServerBackupService` (`server_backup_service.dart`) owns the
  manual (WebUI / ctl / admin API), automatic and pre-update backups; one runs at a time (`busy` = 409). It is
  held by `AdminContext.backups`, so the admin API, the serve scheduler and the self-update hook share it.
  The review-library hold (`ServerSrs.holdForBackup`) is taken for every kind, as before. The service does
  not touch the data-dir lock: serve holds it for its whole life and offline commands get it from
  `withServerRuntime`, so an automatic run can never overlap an offline restore or another process.
- **Files.** All in `<data>/backups/`, kind by name prefix (`server_backup_store.dart`):
  `fushi_server-backup-<local yyyyMMdd-HHmmss>[-n].zip` (manual), `fushi_server-auto-…` (automatic),
  `fushi_server-pre_update-…` (before a self-update). The timestamp is read from the name, not from mtime
  (copy tools change mtime) and not from the zip. Download / delete accept only these three shapes, so `..`,
  separators and NTFS streams cannot reach outside the folder. Same zip format as before
  (`createServerBackup`); owner-only modes unchanged (`restrictServerBackupPath`).
- **Schedule (D14).** `backup:` section in `fushi_server.yaml` (`server_backup_config.dart`): `interval`
  `off | daily | every3Days | weekly` (app names), `time` `HH:MM` in server local time (default `04:00`),
  `documents` (default false), `max_total_gb` (default 5, 0 = no cap). No section = these defaults, so it is on
  for every existing server. The due rule moved to fushi_core (`utils/backup_schedule.dart`,
  `isBackupSlotDue`); the app's `isAutoBackupDue` now calls it, so app and server share one rule (preferred
  slot, catch-up after downtime, calendar-day intervals, clock moved back = due once, an interrupted slot is not
  retried). `ServerBackupScheduler` (`server_backup_scheduler.dart`) runs in `serve` only: interrupted-run check
  at start, first check 30 s after start, then every 15 min; `stop()` cancels the timers and waits for a running
  backup of any kind before `serve` closes the database (a second Ctrl+C still kills; the next start records it
  as interrupted).
- **Skip when unchanged.** Fingerprint = sha1 over relative path + size + mtime of every source file of the
  backup (`serverBackupSourceFiles`: `fushi.db` / `srs4.db` and their `-wal`, the data-dir files the zip takes,
  `documents/` only when included), the config file and the documents switch; computed in an isolate. Skip only
  if it equals the last success's fingerprint **and** that file still exists; a skip counts as satisfied. On a
  busy server the DB `-wal` changes often, so skips mostly happen on idle servers (correct, just less saving).
- **Status** (`server_backup_status.dart`): `<data>/backups/auto_backup_status.json` (inside the backup folder,
  so restoring an old zip never brings back an old status; not a backup name, so it is never listed or
  served). Fields: running (since / name / kind), last success (time / name / bytes), last failure + one-line
  reason, last skip + reason (`unchanged`, `srs_migration_running`), last satisfied, last interrupted,
  fingerprint hash, pruned count, last pre-update (time / name / error). No config content or credentials.
  Status writes are serialized in-process and atomic (tmp + rename).
- **Review library migrating** → the automatic run is recorded as skipped (`srs_migration_running`), not
  failed and not satisfied; the next 15-minute check retries.
- **Interrupted runs.** `runningSinceMs` is written when an automatic / pre-update run starts and cleared when it
  ends. Still there at the next start (serve or `backup run`) → recorded as failed `interrupted`, all
  `fushi_server-*.zip.partial` files are deleted (only names the store recognises), and the due rule waits for
  the next slot. Manual backups do not write the marker, but their `.partial` is cleaned the same way.
- **Retention (D15).** `planServerBackupPrune` reuses fushi_core's `planBackupRetention` with the scheduled
  restore-point policy (`kRestorePointScheduledRetention`: newest always, 48 h all, 7 daily, 4 weekly, 3 monthly)
  and the server's own cap. Only automatic backups are subject to it; pre-update backups keep the newest
  `kRestorePointKeepPreUpdate` (3); manual backups are never pruned. Runs after every successful automatic or
  pre-update backup; the file just written is protected and counts as the newest.
- **Pre-update backup (D16).** `ServerSelfUpdater` gained `beforeInstall`, called after the package is
  downloaded, verified and extracted and right before `swapServerBundle`. `serve` wires it to
  `ServerBackupService.runPreUpdate` via `HeadlessHost.beforeSelfUpdateInstall` (read at call time). It waits for
  a running backup, writes settings + data without `documents/`, prunes to 3, and never throws: a failure (or a
  review-library migration) is logged and stored as `preUpdateError`, and the update proceeds. Why it matters: the
  swapped bundle exits with `kExitSelfUpdated`, and the new version migrates `fushi.db` on its first start (layer
  1 also leaves a `fushi.db`-only pre-update restore point in `support/restore_points/`, but the server has no
  downgrade screen). **Rollback:** stop the service, restore with the **current** binary
  `fushi_server backup restore <data>/backups/fushi_server-pre_update-<time>.zip --yes` (do not start it
  afterwards), then reinstall the older release bundle and start the service. This order is the safe one: the
  current binary reads older packages (schema / format only refuse newer) and keeps `backups/`, `documents/` and
  the device inbox in place, while a pre-4B binary's restore moves `backups/` and `documents/` into
  `<data_dir>.pre-restore-*` (nothing is lost, but the backups and library look gone). The config written back
  by the newer binary is read by older ones (unknown keys are ignored). CLI usage, WebUI "How to restore" and
  the server README say the same.
- **Restore keeps what is not old data.** `restoreServerBackup` used to move every top-level entry of the data
  dir aside, so after a restore all backups were hidden in `<data_dir>.pre-restore-*`, restoring an automatic
  or pre-update backup (no `documents/`) emptied the live library (books / covers / audiobooks / downloads), and
  received device backups vanished with `interconnect/`. Now: `backups/` and the lock file stay where they are;
  when the package has no `documents/` (manifest `includesDocuments: false` and nothing staged under it) the
  live `documents/` stays in place; the device inbox (`interconnect/sync-data/fushi-data/__backups__`) is moved
  into the same relative path under the staged data before the swap (parents created; a stale inbox inside a
  package from before 1a168494eb is dropped in favour of the live one), and moved back on rollback (taken out of
  the placed tree before that tree is deleted). If rollback itself fails while the inbox sits in staging, the
  staging dir is kept instead of deleted. `backup restore` reports `keptDocuments` / `keptDeviceBackups`
  (`--json`) and says both in text.
- **Surfaces.** Admin API (`admin_backups.dart`): `GET /api/admin/backups` adds `kind` / `createdAt` per item,
  `schedule`, `status`, `runningKind`, `backupsDir`, `configFile`; `GET|PUT /api/admin/backups/schedule`
  (partial update, invalid values 400, saved through `AdminContext.updateConfig`); `POST /api/admin/backups/run`
  (automatic backup now: ignores due / unchanged, then prunes). Still not in the AI op catalog (backups hold the
  config). WebUI page "Backups" (`web_ui_backups.dart`, spliced into `web_ui.dart` / `web_ui_en.dart` at three
  points): back up now (manual, documents switch), schedule controls, status lines, list with kind / date / size /
  download / delete, and the offline restore command. CLI: `backup status [--json]` (reads files, no lock),
  `backup run [--if-due]` (offline, takes the lock; `--if-due` makes it usable from cron), `backup settings
  [--interval] [--time] [--[no-]auto-documents] [--max-gb]` (refuses while serve runs). ctl: `backup run`,
  `backup schedule ['<json>']`; `backup ls` shows the kind.
- **Tests.** `test/server_auto_backup_test.dart` (names / path escapes, retention auto vs manual vs pre-update,
  yaml section, due / skip / srs-migration / failure / interrupted, job lock and pre-update wait, pre-update
  retention and failure, scheduler start / stop, admin API schedule / run / delete validation, CLI), additions
  in `server_self_update_test.dart` (hook runs before the swap; a throwing hook does not block) and
  `server_backup_test.dart` (restore keeps `backups/`), `fushi_core/test/backup_schedule_test.dart`.

### Phase 4B open questions

1. Skip-unchanged is coarse on an active server: any DB write changes `fushi.db-wal`, so a server with
   background jobs rarely skips. A content-level check (DB `data_version` / change counters) would skip more, at
   the cost of opening the DB from the fingerprint code.
2. The pre-update backup happens inside the self-update job; the client only sees the update status, not the
   backup result (it is in the server's backup status / WebUI / log). Surfacing it in `HostUpdateStatus` would
   need a protocol field.
3. ~~A backup larger than the free disk space fails with the I/O error; there is no free-space check before
   starting (the app phase 2 has none either).~~ *Closed in phase 5 (D18–D20): every backup checks free space
   before it writes.*
4. Offline `backup run` / `backup status` show the schedule from the config file; a `serve` started later picks
   it up, but `backup settings` while serve runs is refused rather than forwarded to the admin API.
5. Real check was on Windows with `dart run` (no native dictionary / torrent libraries); not checked in a
   release bundle, on Linux, under systemd stop timeouts, or with a real self-update swap.

## Phase 5 as implemented (2026-11-25): received backups on the app host, free-space check

Two open items from #4470 (phase 4A open question 1, phase 4B open question 3).

### Received from other devices (app as Interconnect host, D17)

- **Where the copies are.** The app host's WebDAV root is `<databaseDirectory>/sync-data`, so the inbox is always
  `<databaseDirectory>/sync-data/fushi-data/__backups__/<device key>/<id>/`
  (`appInterconnectSyncRoot`, `fushi/lib/src/sync/auto_backup/received_device_backups.dart`). Disk reads and
  deletes stay in fushi_core `DeviceBackupInbox` (shared with the headless server); `ReceivedDeviceBackups` adds
  the two app-side rules: this device's own key (`backupDeviceKey` of the sync device id, same source as the
  restore point metadata) is never listed or deleted, and the directory walk runs in a background isolate.
- **Restore points page.** A "Received from other devices" section after the folder / cloud / server copy
  sections, shown only when the inbox has other devices' copies. One card per device: name from the newest
  meta (fallback "Unnamed device (key prefix)"), count, total size, newest date, incomplete count. Per copy:
  date, size, app version / schema, contents; **Export** (the same Save As / share flow as a local restore
  point, file name `fushi-backup-<device key>-<id>.zip`) and **Delete** (inline confirm). Per device: **Delete
  all from this device** (inline confirm). A hint says restoring is only possible on the device the backup came
  from (that device copies it back from the server), so it is not offered here. The host's own restore point
  list is unchanged.
- **ctl / CLI.** `GET /api/admin/restore-points/received` (groups + paths, own key excluded) and
  `POST /api/admin/restore-points/received/delete` (`device`, optional `id`; no id = the whole device), which
  requires `confirm: true` because the delete cannot be undone (op descriptions `backup.received.list` /
  `backup.received.delete`, risk irreversible). CLI (fushi_cli): `backup received` and
  `backup received-delete <device> [<id>] --yes`.
- **The host's own backups do not pack the inbox.** Checked: `BackupService.createBackup` only packs explicit
  roots (`fushi_books`, `audiobooks`, `custom_fonts`, `game_covers`, dictionary resources, `srs_media`);
  `sync-data/` is never one of them, so manual exports, scheduled points and copies never contain the inbox
  (the headless server excludes it explicitly since phase 4B). No change needed.

### Free-space check before writing a backup (D18–D20)

- **One platform implementation.** Rust `ffsrs_volume_free_bytes(path) -> i64` (`native/fushi_fsrs/src/lib.rs`,
  -1 = unknown, wraps `store/compact.rs` `free_bytes`, the same `statvfs` / `GetDiskFreeSpaceExW` code that
  guards review-library compaction) and `ffsrs_volume_id(path, *mut u64) -> i32` (1 = written; POSIX `st_dev`,
  Windows `GetVolumePathNameW` root + `GetVolumeInformationW` serial, so mount points are told apart; a path that
  does not exist gives 0); ABI 8 → 9. Dart: `FfiFsrsEngine.volumeFreeBytes` / `FfiFsrsEngine.volumeId` walk up to
  the first existing ancestor (the backups folder may not exist yet). fushi_core does not depend on fushi_srs, so
  the check lives in fushi_core `database/free_space.dart` (`ensureFreeSpace`, `NotEnoughSpaceException`,
  `kNotEnoughSpaceError = 'not_enough_space'`, `kBackupSpaceMarginBytes` = 64 MiB like compaction's `MARGIN`)
  and the app (`main`) and the server CLI entry register both probes (`registerVolumeFreeBytes(free, volumeId:)`).
  Every caller also accepts injected probes (tests).
- **Estimate (D18).** Uncompressed upper bound plus margin: a compressed zip is never larger than its inputs,
  and media / documents barely compress, so no factor is applied. Temp snapshot copies are counted on the
  volume they go to. Targets on the same volume are summed, grouped by **volume identity**
  (`ffsrs_volume_id`), each group compared with its smallest free reading. If any target has no identity, all
  targets are treated as one volume: every need summed against the smallest reading (conservative; a first
  version grouped by equal free readings, which a write between the two reads broke, under-counting).
  Unknown free space (no probe, platform cannot tell) → write as before.
  - App scheduled point: `fushi.db` + `srs4.db` (each with `-wal`; srs only when available) + the file
    categories and review media from `BackupService.estimateFileCategoryBytes`, which runs **the same collector
    as `createBackup`** (`_collectFileCategories`: dictionaries, books and downloaded manga, audiobooks, referenced
    fonts, every referenced video file, `local_audio_*.db`, game covers, `srs_media/`), on the store root (custom
    folder or default); the two databases again on the system temp volume (`createBackup` `VACUUM INTO`s them
    there first). A first version walked a separate "category → folder" table and missed videos and local
    audio; `backup_categories_test.dart` now fails if any category in `kBackupFileCategories` or review media
    estimates to 0 or differs from what `createBackup` packs.
  - App pre-operation / pre-update point: the live database file(s) + `-wal` on the restore point root.
  - Copy back to this device: the copy's `totalBytes` on the database directory (staging and store are there).
  - Server: `serverBackupSizeEstimate` = every source file of the backup (`serverBackupSourceFiles`: DB files,
    data directory, `documents/` only when included) + config on `backups/`; `fushi.db` + `srs4.db` (+ `-wal`)
    again on `<data>/tmp/` (the snapshot copies). Shared by the service and the offline `backup create`.
- **Outcomes (D19).**
  - App scheduled: failed with `not_enough_space` (status row + localized text `auto_backup_error_not_enough_space`);
    notified once per streak (a repeat failure for the same reason does not toast again; a success resets it).
  - App pre-operation for Replace: refused before anything changes (unchanged phase 2 behaviour), the toast /
    ctl error now says the reason is free space. Pre-operation points taken through
    `takePreOperationRestorePoint` (sync download, review migration) keep continuing without a point, with the
    reason localized in the notice.
  - Phase 1 pre-update snapshot: not taken, the status records `error: not_enough_space` (the startup notice
    shows the localized reason), migration continues.
  - Copy back: refused before the download starts (error code `not_enough_space`).
  - Server automatic: failed, `lastError: not_enough_space` in status + log (WebUI shows "Not enough free disk
    space; not started"), not counted as satisfied, retried at the next check.
  - Server manual and "run now" (admin API `POST /api/admin/backups` and `POST /api/admin/backups/run`): the job
    claims the lock, checks space, and the handler waits only for that check (`ServerBackupStart.preflight`,
    `adminBackupStartedResponse`): **507** `{"error":"not_enough_space",...}`; if the estimate itself fails
    (unreadable data directory, isolate error) **500** `{"error":"preflight_failed"}` with the raw text only in
    the log; a run skipped as unchanged answers 202. The WebUI toasts the localized text for both buttons;
    `lastError` also shows it; `fushi_server ctl backup create|run` call the same admin API. Offline
    `backup create` prints the reason and exits non-zero.
  - Server pre-update: skipped with `preUpdateError: not_enough_space`, the update proceeds (D16).
- **Test-only hook.** `FUSHI_SERVER_FREE_BYTES_OVERRIDE=<bytes>` (server only, `kServerFreeBytesOverrideEnv`)
  reports that value for every volume (no volume identity, so the conservative sum applies), so a real `serve`
  can be shown failing for space without filling a disk. When set, the CLI prints a warning at startup and every
  backup's space check logs a `WARNING … (test only)` line; the server README says not to set it in production.
- **ctl received list.** `GET /api/admin/restore-points/received` answers 503 `device_identity_unavailable`
  (raw error only in the log) when this device's key cannot be read, instead of a bare 500: without it the route
  cannot guarantee that this device's own copies are excluded.
- **Tests.** Rust `tests::volume_free_bytes_abi`; fushi_srs `volume_free_bytes_test.dart` (real library);
  fushi_core `free_space_test.dart` (same-volume sum, separate volumes, unknown, registered probe, pre-operation
  refused, pre-update status); server `server_auto_backup_test.dart` group "写之前查空间（第五期）" + admin API 507;
  app `auto_backup_controller_test.dart` group "写之前查空间（第五期）" (scheduled fails / notify once / recovers,
  estimate counts file trees, pre-operation refused); received backups: `received_device_backups_test.dart`,
  `restore_points_page_test.dart`, `ctl_data_routes_test.dart`, fushi_cli `data_commands_test.dart`.

### Phase 5 open questions

1. The estimate is an upper bound: a nearly-full disk may refuse a backup that would have fit after compression.
   A tighter estimate (per-category compression ratios from the last successful backup) is possible later.
2. Folder / cloud / server copies are not space-checked on the target (the remote side reports its own quota
   errors, `cloud_quota`); only local writes are.
3. The received-backups section was checked by widget tests only; the app was not launched.
4. **iOS free space.** `statvfs` `f_bavail` excludes purgeable space (caches iOS frees on demand), while
   `volumeAvailableCapacityForImportantUsage` includes it, so on a full-looking iPhone the check may refuse a
   backup the system would have made room for. Using the Foundation value needs a Swift / Objective-C shim
   (cannot be built in this batch); left as a follow-up.
5. The app fingerprint (skip-unchanged) still walks the `contentTreeRoots` table, which has no videos / local
   audio entries; a change only in those files is not seen as a change (pre-existing, phase 2). The estimate no
   longer uses that table.

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
| D12 | Phase 4: copies to the paired server | part of the cloud target / own target | **Own target "Copy to server"** (user 2026-11-25: phase 4 = devices → server + server self-backup; defaults below recommended, maintainer may change): independent of the cloud, uses the Interconnect channel sync uses, off by default, own status / key / notify-once; the cloud target stops picking Interconnect; one "Also upload on mobile data" switch covers cloud and server. |
| D13 | Retention of copies on the server | like the cloud / like local / server decides | **Like local** (48 h all, 7 daily, 4 weekly, 3 monthly, 5 GB), the device prunes only its own copies; other devices' and copied-back copies are never auto-deleted; the server never auto-deletes device copies, its admin can (WebUI / admin API / ctl). |
| D14 | Server self-backup: when / what | off / scheduled | **On by default: daily at 04:00 server local time** (interval off / daily / every 3 days / weekly, time configurable), catch-up after downtime, skipped when nothing changed, `documents/` excluded by default (setting to include). One job at a time with manual backups; skipped (not failed) while the review library migrates; interrupted runs detected and cleaned. *Recommended default, maintainer may change.* |
| D15 | Server automatic-backup retention | flat keep-N / tiered | **Same tiers as D3 (48 h all, 7 daily, 4 weekly, 3 monthly), newest always kept, 5 GB cap (configurable, 0 = none).** Manual and pre-update backups are never pruned by it. *Recommended default, maintainer may change.* |
| D16 | Backup before a server self-update | none / block on failure / proceed on failure | **Settings + data (no documents) before the bundle swap, newest 3 kept; a failure is logged and shown, the update still proceeds** (same as phase 1). Rollback = restore that zip with the current binary (do not start it), then reinstall the older bundle. *Recommended default, maintainer may change.* |

| D17 | App as Interconnect host: received device backups | not shown / list + delete / list + export + delete + restore | **List, export and delete on the Restore points page ("Received from other devices"); no restore on the host** (a backup belongs to the device it came from). Shown whenever the inbox has other devices' copies, also after hosting was turned off (leftovers stay deletable); this device's own key is excluded; deletes ask inline, ctl delete needs `confirm` / CLI `--yes`. *Recommended default, maintainer may change.* |
| D18 | How much space a backup needs | compressed guess / uncompressed upper bound | **Uncompressed sum of the inputs + 64 MiB margin**, computed from the same file map `createBackup` packs (app) / the same source list the server zip uses; temp snapshot copies counted on their volume; targets on the same volume (by volume identity) summed, and all targets summed against the smallest reading when an identity is missing; unknown free space → write. *Recommended default, maintainer may change.* |
| D19 | Not enough space | try anyway / refuse | **Refuse before writing anything**: app scheduled → failed `not_enough_space`, notified once per streak; Replace → refused with that reason; other pre-operation points and the phase-1 snapshot → skipped with the reason, the operation / migration continues; server automatic → failed in status; manual → HTTP 507; pre-update → skipped, update proceeds (D16). *Recommended default, maintainer may change.* |
| D20 | Where the platform free-space call lives | Dart per platform / fushi_compute / fushi_fsrs | **fushi_fsrs `ffsrs_volume_free_bytes` + `ffsrs_volume_id` (ABI 9)**, reusing the compaction helper (one `statvfs` / `GetDiskFreeSpaceExW` implementation; fushi_fsrs already exports non-SRS utilities such as zstd); registered into fushi_core by the app / server entry because fushi_core does not depend on fushi_srs. *Recommended default, maintainer may change.* |

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
D14–D16（用户 2026-11-25 定第 4 期两块都做，这三条按建议默认实现，维护者可改）：服务端自动整机备份默认开，每天服务端本地 04:00
（可关 / 每天 / 每 3 天 / 每周，时刻可改），停机错过了下次启动补跑，没变化就跳过，默认不带 documents/（可开）；与手动备份共用一把作业锁，
复习库换代迁移中记「跳过」不算失败，写到一半被杀下次启动记「中断」并清掉半截。自动备份按 D3 同一套分层保留、5 GB 上限（可改，0 = 不限），
手动备份与更新前备份从不被它删。远程更新换包之前先备份设置与数据（不带 documents/，留最新 3 份），失败只记录、更新照样进行；回滚 = 先停服，用
现在这版程序还原那份更新前备份（还原完先不启动），再装回旧版程序启动（第 4B 期之前的旧程序还原时会把 `backups/` 与 `documents/` 挪进
pre-restore 目录）。还原时 `backups/`、设备复制来的备份原地留着；备份不含 `documents/` 时现有的 `documents/` 也原地不动。

D12–D13（用户 2026-11-25 定第四期 = 设备备份到服务器 + 服务器自己定时备份；以下为推荐默认，维护者可改）：「复制到服务器」是单独的副本目标，
与云端互不相干（两个都开就各传一份），用同步在用的那条互联通道，默认关，状态 / 键 / 失败提示各自一份；云端副本不再选互联；「也用移动数据
上传」云端与服务器共用一个开关。服务器上的副本由设备按本机规则修剪自己写的（48 小时全留、7 日 4 周 3 月、5 GB），别的设备的、取回的从不
自动删，服务器自己也从不自动删，管理员可在 WebUI「设备备份」页 / admin API / ctl 里删。app 当互联 host 时收到的副本第五期起在还原点页列出（D17）。
复制开关开着却没有可用服务（比如云端只配了互联）时，那个目标的状态记「没有服务」并只提示一次，开关不替用户关；云端 / 服务器上自动删除只动
本机目录里的副本，还原点页删别的设备的副本按列出来的那一份删。

D17–D20（第五期，按建议默认实现，维护者可改）：app 当互联 host 时，还原点页多一段「从其他设备收到的备份」，按设备分组（名字、份数、总大小、最新日期、
不完整份数），每份可导出、可删（行内确认），也可删一台设备的全部；不在 host 上提供恢复（备份属于原来那台设备），本机自己的设备键不列；只要收件箱
里有别的设备的副本就显示，host 关了也照样能清；ctl / CLI 也能列、能删（删要 `confirm` / `--yes`）。app 自己的备份 / 导出本来就不打包收件箱，
不用改。写任何备份之前先查空间：按不压缩的输入总和 + 64 MiB 余量估，临时快照算在它落的那个卷上，按卷身份（`ffsrs_volume_id`：POSIX `st_dev`、Windows 卷根 + 序列号）把同一个卷上的
目标合计，拿不到卷身份就全部合计、对比最小的读数；app 的估算与 `createBackup` 走同一个文件收集器（视频、本地音频不再漏算）；查不到可用空间就
照常写；不够就一个字都不写——app 定时备份记失败 `not_enough_space`、同一原因只提示一次，「替换」拒绝并说明原因，其余操作前还原点与更新前快照
跳过并记原因、操作 / 迁移照常；服务端自动备份记失败，手动备份与「立即跑」回 507（估算本身失败回 500 `preflight_failed`），更新前备份跳过、更新照常（D16）；
`FUSHI_SERVER_FREE_BYTES_OVERRIDE` 只给测试用，设了会在启动和每次备份日志里警告。平台实现只有一份：fushi_fsrs 的
`ffsrs_volume_free_bytes` / `ffsrs_volume_id`（ABI 升到 9，复用复习库压缩的 `free_bytes`），由 app / 服务端入口登记进 fushi_core。

## Naming

New code uses `restore_point*` / `auto_backup*`. `srs_sync_v1_removed_guard_test` bans the removed
SRS backup names (`srs_backup_store`, `srs_backup_retention`, `srs_point_in_time_restore`, ...).
