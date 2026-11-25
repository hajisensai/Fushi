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
  `<id>-fushi-scheduled/backup.zip` (same zip format as a manual export, entries native-deflated up to
  512 MB each, larger ones stored) plus meta `categories`, `excludedCategories`, `srsMedia`. A pre-operation
  point holds `fushi.db` (`VACUUM INTO` on a separate read-only connection while the app is running) and,
  when the review DB is open, `srs4.db` (kernel `snapshotInto`); `RestorePointRollbackPlan.database`
  picks which file of a point to swap. Points being written are registered in-process so a concurrent
  `prune` never deletes them. A desktop custom folder is just another store root (scheduled points only).
- **Retention** is one pure function, `planBackupRetention` (`fushi_core/lib/src/utils/backup_retention.dart`),
  shared with the Lapis template backups (`keepMinimum: 10, keepAllWithin: 90 days`, unchanged behaviour).
  Scheduled: newest always kept, 48 h all, then newest per age-bucket day (7), week (4), month (30-day
  buckets, 3), then a 5 GB cap trimming oldest first; the point just written is protected. Every kept
  point claims its buckets. Pre-operation: newest 5. Pre-update / pre-rollback: unchanged (3 each).
- **Schedule** (`fushi/lib/src/sync/auto_backup/`): due rule in `auto_backup_schedule.dart`. With a
  preferred time T and interval N: due when the last *satisfied* run (success, or skipped because nothing
  changed) is before `latestSlot(T) - (N-1) days`; without T: `now - lastSatisfied >= N days`. The
  overdue warning also uses "last satisfied" (a skipped run means the newest point is still current).
  Checks: first idle task after the home page is up (`AppModel.startUpdateChecks`), app resume, and every
  15 min on desktop. Status (`restore_points/auto_backup_status.json`, a file so it survives a DB replace)
  keeps the last result, error and a size+mtime fingerprint of the DB files and the ticked content trees.
  One run at a time; it shares `AppModel.backupExportActive` with manual exports and shows in the
  background-tasks indicator. Failures: toast once + warning row, next attempt at the next due check.
- **Review media (D2)** is split by `createBackup(includeSrsMedia:)`, not by a new category: a backup
  without `srs_media/` entries leaves the local media tree untouched on replace.
- **Forced points**: before Replace on the Restore points page / ctl (abort if the point fails), before
  applying a sync-compare plan that contains "use remote" (the only flow that overwrites local data from
  cloud / Interconnect; plain sync is merge-only), and before the Anki migration
  (`runSrsAnkiMigration(beforeImport:)`). For the last two a failed point is reported and the operation
  continues. Overwrite-import snapshot and DB-check backups stay as they were and are listed.
- **Restore points page** replaces "Recover library" (same route, orphan-folder recovery kept below the
  list). Fill in missing works for any raw main-DB copy and for the DB extracted from a scheduled zip.
  Replace: raw-DB points use the phase-1 swap (current DBs become `pre_rollback` points), scheduled zips
  use the overwrite import (`importSettings: true`). Legacy copies (pre-overwrite, DB check) offer Fill in
  / Export / Delete but not Replace (the rollback journal addresses store ids).
- **Known gap:** replacing from a scheduled point whose categories exclude content (books, videos,
  dictionaries…) uses the overwrite-import semantics, which drop those library rows (files stay on disk
  and show up as orphan folders). The page says so before confirming; a "keep what the backup does not
  carry" replace mode needs a change in `restoreBackup`.
- **ctl**: `GET /api/admin/restore-points`, `GET /api/admin/auto-backup/status`,
  `POST /api/admin/auto-backup/run` (undo deletes the point), `POST /api/admin/restore-points/restore`
  (`mode` fill / replace, needs `confirm: true`).

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
| D1 | Scheduled backups on by default? | on / off | **On, daily, small set.** Layer 1 is always on, no setting. |
| D2 | Review media (card images / audio) in scheduled backups? | include / exclude / incremental by hash | **Notes + history included; media off by default with a switch.** |
| D3 | Retention | flat keep-N / tiered / age-based | **Tiered: 48 h all, 7 daily, 4 weekly, 3 monthly, 5 GB cap. Pre-update: newest 3 per DB.** |
| D4 | Off-device copies via cloud backend | now / later | **Later (phase 3).** User folder first. |
| D5 | Downgrade-screen rollback | replace with newest compatible snapshot / reverse-migrate ("Downgrade & Quit") | **Replace**, keep the newer DB as a `pre_rollback` point, state what is lost. |
| D6 | Misleading Anki-migration text | fix now separately / re-point with phase 2 | **Re-point at the Restore points page in phase 2** (forced backup before the migration makes it true again). |
| D7 | What to back up / when | fixed / user choice | **User choice:** category checklist + interval + optional preferred time (user request). |

## 决策摘要（中文）

用户 2026-11-25 按提案建议拍板，维护者可改：D1 定时备份默认开、每日、小集合（更新前快照常开、无开关）；
D2 复习笔记与记录进备份，卡片媒体默认不进、可开；D3 分层保留（48 小时全留、7 日 4 周 3 月、5 GB 上限），
更新前快照每库留最近 3 份；D4 云端异地副本放第三期；D5 降级屏回滚 = 换回最新兼容快照、当前库另存为
`pre_rollback` 还原点；D6 Anki 迁移提示随第二期改指向还原点页；D7 备份内容、频率与偏好时间由用户选。

## Naming

New code uses `restore_point*` / `auto_backup*`. `srs_sync_v1_removed_guard_test` bans the removed
SRS backup names (`srs_backup_store`, `srs_backup_retention`, `srs_point_in_time_restore`, ...).
