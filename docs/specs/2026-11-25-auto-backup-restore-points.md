# Auto backup and update rollback (restore points)

Status: phase 1 implemented (branch `feat/auto-backup-p1-update-snapshot`), phase 2 implemented (branch
`feat/auto-backup-p2-scheduled`, stacked on phase 1). Owner: auto-backup session. Proposal with the comparison of other apps:
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
- **Left for phase 3:** macOS security-scoped bookmark for the custom folder (stored as a plain path now);
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

## 决策摘要（中文）

用户 2026-11-25 按提案建议拍板，维护者可改：D1 定时备份默认开、每日，每份都是整库、文件只默认带字体（更新前快照常开、无开关；
审查后用户 2026-11-25 改为「整库 + 挑文件」，原为按类别的小集合、会剥掉书库行）；
D2 复习笔记与记录进备份，卡片媒体默认不进、可开；D3 分层保留（48 小时全留、7 日 4 周 3 月、5 GB 上限），
更新前快照每库留最近 3 份；D4 云端异地副本放第三期；D5 降级屏回滚 = 换回最新兼容快照、当前库另存为
`pre_rollback` 还原点；D6 Anki 迁移提示随第二期改指向还原点页；D7 频率与偏好时间由用户选，内容只挑带哪些大文件
（书、有声书、视频、词典、字体、本地音频、游戏封面）与复习媒体开关，书库、进度、统计、设置与复习笔记每次都在（同日审查后
用户改定，原为完整类别勾选）。从整库定时点「替换」：整库换回，包里带着的文件换回，没带的文件在本机原样不动、书库条目照样保留。

## Naming

New code uses `restore_point*` / `auto_backup*`. `srs_sync_v1_removed_guard_test` bans the removed
SRS backup names (`srs_backup_store`, `srs_backup_retention`, `srs_point_in_time_restore`, ...).
