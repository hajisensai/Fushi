import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../utils/ttu_sanitize.dart';
import '../utils/video_book_uid.dart';
import 'book_format.dart';
import 'collection_order.dart';
import 'media_kind.dart';
import 'pref_codec.dart';
import 'sync_tombstone_kind.dart';
import 'tables.dart';

part 'database.g.dart';

/// Thrown when the on-disk database was created by a NEWER build of Hibiki than
/// the one currently running (`db user_version > code schemaVersion`).
///
/// 降级保护：当用户用旧版应用打开由新版创建的库时，绝不 DROP/迁移/重建，而是抛出此
/// 异常让打开失败、事务回滚、库文件原样保留，并由 UI 提示用户更新应用。这是修复
/// 「旧 app 启动把用户数据库降级破坏」整类事故的根因拦截。
class FushiDatabaseDowngradeException implements Exception {
  /// The schema version stored in the on-disk DB file (created by a newer app).
  final int dbVersion;

  /// The schema version this (older) build of the code knows about.
  final int appSchemaVersion;

  const FushiDatabaseDowngradeException({
    required this.dbVersion,
    required this.appSchemaVersion,
  });

  @override
  String toString() =>
      'FushiDatabaseDowngradeException: database was created by a newer '
      'version of Fushi (schema v$dbVersion); this app only understands '
      'schema v$appSchemaVersion. Opening was refused to protect your data.';
}

/// Thrown when the database could NOT be opened even after the full WAL/IOERR
/// recovery ladder (checkpoint → DELETE journal → physical sidecar rebuild)
/// ran — i.e. the main `fushi.db` file itself is corrupt, not just a stale
/// `-wal` / `-shm` sidecar. Mirrors [FushiDatabaseDowngradeException]: it is a
/// dedicated, app-recognisable terminal type so the app layer can show an
/// actionable "import a backup / clear data" notice INSTEAD of looping the
/// generic init-error Retry button forever (TODO-905 root cause: a stale
/// sidecar made `PRAGMA journal_mode=WAL` raise SqliteException(1546), and Retry
/// re-ran open against the same untouched bad sidecar = infinite "can't open").
class FushiDatabaseUnrecoverableException implements Exception {
  /// Absolute path of the database file that could not be recovered.
  final String dbPath;

  /// The underlying error from the final open attempt (kept for diagnostics).
  final Object cause;

  const FushiDatabaseUnrecoverableException({
    required this.dbPath,
    required this.cause,
  });

  @override
  String toString() =>
      'FushiDatabaseUnrecoverableException: the database file at "$dbPath" '
      'could not be opened even after WAL/sidecar recovery. It is likely '
      'corrupt and must be restored from a backup or cleared. Cause: $cause';
}

/// SQLite primary result codes that a stale/locked/corrupt `-wal`/`-shm`
/// sidecar surfaces as when opening + switching to WAL after a hard kill:
///   - 10 = `SQLITE_IOERR` family (1546 = `SQLITE_IOERR_SHMOPEN`, SHMMAP, …) —
///     the exact code reported in TODO-905 (Windows mmap-lock residue);
///   - 14 = `SQLITE_CANTOPEN` family (526 = `SQLITE_CANTOPEN_*`) — the same
///     hard-kill residue surfaces here on other OS/state combinations
///     (e.g. a sidecar SQLite can't open/recreate).
/// Both mean "the MAIN db may be fine but a sidecar is the problem". Recovery
/// triggers on either, then PROVES the main db is healthy (read-only open) before
/// touching anything — so a genuinely missing/corrupt/permission-denied main db
/// is NOT mistaken for a sidecar problem (it falls through to unrecoverable).
const int _kSqliteIoErr = 10; // SQLITE_IOERR
const int _kSqliteCantOpen = 14; // SQLITE_CANTOPEN
const int _kSqliteNotADb = 26; // SQLITE_NOTADB

bool _isSidecarOpenError(Object e) {
  if (e is! sqlite3.SqliteException) return false;
  final int primary = e.extendedResultCode & 0xFF;
  // IOERR(10) / CANTOPEN(14): the classic hard-kill sidecar residue. NOTADB(26):
  // a non-SQLite-header file — could be a corrupt MAIN db, so it also enters the
  // ladder, where _mainDbIsHealthy() proves whether the main db is fine (recover)
  // or itself bad (terminal). All three are gated by the health probe below, so
  // a corrupt main db is never mistaken for a stale sidecar.
  return primary == _kSqliteIoErr ||
      primary == _kSqliteCantOpen ||
      primary == _kSqliteNotADb;
}

/// The 16-byte magic header every SQLite database file starts with
/// ("SQLite format 3\u0000"). See https://www.sqlite.org/fileformat.html .
final List<int> _kSqliteMagic = 'SQLite format 3\u0000'.codeUnits; // 16 bytes

/// Whether the MAIN `fushi.db` file is itself a structurally valid SQLite
/// database, judged ONLY by its file header — deliberately WITHOUT opening a
/// connection (a read-only open of a WAL db still engages the `-wal`/`-shm`
/// sidecar, which is the very thing that is broken here, so it would falsely
/// report a healthy main db as bad). Gates sidecar recovery: we only ever delete
/// `-wal`/`-shm` when the main db's header is intact, so a corrupt/missing main
/// db can never be mistaken for a stale sidecar (it stays unrecoverable instead
/// of triggering a destructive delete).
bool _mainDbHeaderIsValid(String path) {
  final File file = File(path);
  if (!file.existsSync()) return false;
  try {
    final RandomAccessFile raf = file.openSync();
    try {
      if (raf.lengthSync() < _kSqliteMagic.length) return false;
      final List<int> head = raf.readSync(_kSqliteMagic.length);
      for (int i = 0; i < _kSqliteMagic.length; i++) {
        if (head[i] != _kSqliteMagic[i]) return false;
      }
      return true;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}

/// Opens [dbFile] robustly. Layer 0 is the normal fast path; only a
/// sidecar-class open error (stale/locked/corrupt `-wal`/`-shm` after a hard
/// kill) drops into the recovery ladder. [allowSidecarDelete] gates the physical
/// sidecar rebuild (Layer 2): only the MAIN process may delete `-wal`/`-shm`; the
/// separate `:popup` process passes false and backs off (throws) so two
/// processes never race to delete the same sidecar (TODO-905 D3).
///
/// Throws [FushiDatabaseUnrecoverableException] when the main DB file itself is
/// corrupt (recovery exhausted) so the app layer can stop the Retry loop.
Future<QueryExecutor> _openWithRecovery(
  File dbFile, {
  required bool allowSidecarDelete,
}) async {
  final String path = dbFile.path;
  void applyPragmas(CommonDatabase db) {
    // BUG-772：busy_timeout 前置，让下面的 journal_mode=WAL 切换本身也受 5s busy 超时
    // 约束——视频硬崩留脏 -wal/-shm 时，probe-open 的 WAL 切换可能因锁争用长阻塞 UI
    // isolate（与主 raster 根因并存的独立同步冻结隐患）。
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA foreign_keys = ON');
  }

  // ── Layer 0 — normal path. Probe-open with a raw sqlite3 connection applying
  //    the exact same PRAGMAs drift would. This surfaces the open error eagerly
  //    (createInBackground would otherwise defer it to the first query). On
  //    success we close the probe and hand drift a fresh background connection.
  try {
    final sqlite3.Database probe = sqlite3.sqlite3.open(path);
    try {
      applyPragmas(probe);
    } finally {
      probe.close();
    }
    return NativeDatabase.createInBackground(dbFile, setup: applyPragmas);
  } catch (e, stack) {
    // Not a sidecar-class error → nothing recovery can safely do, surface it.
    if (!_isSidecarOpenError(e)) rethrow;
    // The error class is ambiguous (a corrupt MAIN db can also raise
    // CANTOPEN/NOTADB): only recover if the main db's header is a valid SQLite
    // file. Otherwise it is a corrupt/missing main db → terminal, do NOT delete
    // any sidecar.
    if (!_mainDbHeaderIsValid(path)) {
      throw FushiDatabaseUnrecoverableException(dbPath: path, cause: e);
    }
    debugPrint('[fushi-db] sidecar open error on "$path" '
        '(main db healthy → recovering): $e\n$stack');
  }

  // ── Layer 1 — checkpoint the WAL back into the main DB, then leave WAL mode.
  //    A raw connection that does NOT pre-set WAL can usually still open even
  //    when a stale -shm is poisoned; wal_checkpoint(TRUNCATE) flushes every
  //    already-committed WAL frame into fushi.db (NO DATA LOSS), then
  //    journal_mode=DELETE drops the -wal/-shm cleanly. MUST run before any
  //    physical sidecar delete (Layer 2) so committed-but-uncheckpointed
  //    transactions are preserved.
  try {
    final sqlite3.Database recover = sqlite3.sqlite3.open(path);
    try {
      recover.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      recover.execute('PRAGMA journal_mode=DELETE');
    } finally {
      recover.close();
    }
    debugPrint(
        '[fushi-db] Layer 1 recovery OK (checkpoint+DELETE) for "$path"');
    return NativeDatabase.createInBackground(dbFile, setup: applyPragmas);
  } catch (e, stack) {
    if (!_isSidecarOpenError(e)) rethrow;
    debugPrint('[fushi-db] Layer 1 still failing on "$path": $e\n$stack');
  }

  // ── Layer 2 — physical sidecar rebuild. Layer 1 could not even open a raw
  //    connection (sidecar too poisoned). Only the MAIN process is allowed to
  //    delete; the :popup process backs off so the two never race.
  if (!allowSidecarDelete) {
    throw FushiDatabaseUnrecoverableException(
      dbPath: path,
      cause: 'sidecar open error in a non-main (:popup) process; backing off '
          'so the main process performs sidecar recovery first',
    );
  }
  await _rebuildSidecar(dbFile);
  try {
    return NativeDatabase.createInBackground(dbFile, setup: applyPragmas);
  } catch (e, stack) {
    if (!_isSidecarOpenError(e)) rethrow;
    // ── Layer 3 — sidecar gone yet still failing ⇒ the main fushi.db is
    //    corrupt after all. Terminal: hand the app a recognisable type so it can
    //    stop the Retry loop and offer restore/clear instead of looping.
    debugPrint(
        '[fushi-db] Layer 2 rebuild failed, DB unrecoverable: $e\n$stack');
    throw FushiDatabaseUnrecoverableException(dbPath: path, cause: e);
  }
}

/// Layer 2 helper: snapshot then physically remove the stale `-wal` / `-shm`
/// sidecars so SQLite rebuilds them from a clean `fushi.db`.
///
/// 🔴 Data-safety invariant (TODO-905 red line): this NEVER touches the main
/// `.db` file — it only deletes the `$path-wal` / `$path-shm` suffixes. A
/// `.corrupt-bak` snapshot of the main DB + each sidecar is taken first (mirrors
/// backup_service's `.pre-restore.bak`) so a user can hand-recover the last
/// un-checkpointed writes if needed.
Future<void> _rebuildSidecar(File dbFile) async {
  final String path = dbFile.path;
  final File wal = File('$path-wal');
  final File shm = File('$path-shm');

  // Snapshot the main DB + sidecars before deleting anything (D1: 数据安全兜底).
  final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
  Future<void> snapshot(File src, String suffix) async {
    if (await src.exists()) {
      try {
        await src.copy('$path.corrupt-bak-$stamp$suffix');
      } catch (e) {
        debugPrint(
            '[fushi-db] snapshot of "${src.path}" failed (non-fatal): $e');
      }
    }
  }

  await snapshot(dbFile, '.db');
  await snapshot(wal, '.db-wal');
  await snapshot(shm, '.db-shm');

  // Delete ONLY the sidecar PATHS; the main .db is left byte-for-byte intact.
  // Handles either a normal sidecar file OR a stray directory occupying the
  // path (a hard kill can leave the path unusable as a file — the cause of the
  // CANTOPEN); both are removed so SQLite can recreate a clean sidecar.
  Future<void> deleteSidecar(String sidecarPath) async {
    final FileSystemEntityType type = await FileSystemEntity.type(sidecarPath);
    if (type == FileSystemEntityType.file) {
      await File(sidecarPath).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(sidecarPath).delete(recursive: true);
    }
  }

  await deleteSidecar('$path-wal');
  await deleteSidecar('$path-shm');
  debugPrint('[fushi-db] Layer 2: deleted stale -wal/-shm for "$path" '
      '(main .db untouched, .corrupt-bak-$stamp snapshot kept)');
}

/// 主库在 support 根下的文件名。唯一真相源：除了 [_openDb] 自身，app 层判定「这台机器
/// 上是否已经有一个跑过的安装」时也要认这个文件（见 `AppPaths` 的默认 documents
/// 布局判据），故抽成导出常量而不是各处重复字面量。
const String fushiDatabaseFileName = 'fushi.db';

/// 旧主库文件名（Fushi 改名前的 Hibiki 时代）。只允许迁移代码引用：[_openDb] 在
/// 打开任何连接前把它整套（.db / -wal / -shm）改名成 [fushiDatabaseFileName]，
/// app 层「本机是否已有安装」的判据也要兼看它（旧安装升级后第一次开库前旧名还在）。
const String legacyHibikiDatabaseFileName = 'hibiki.db';

/// Fushi 终局清算 W1：`hibiki.db` → `fushi.db` 一次性文件改名，必须发生在任何
/// SQLite 连接打开之前（WAL 库的 `-wal`/`-shm` 与主文件名绑定，开着连接改名等于
/// 撕裂 sidecar）。改名顺序刻意是 **sidecar 先、主文件最后**：判据只看两个主文件
/// （`fushi.db` 不存在且 `hibiki.db` 存在才迁移），所以中途被杀后重启会重新进入
/// 本分支，把剩下的文件补完 —— 反过来先改主文件的话，残留的 `hibiki.db-wal` 里
/// 已提交的 WAL 帧会被永远遗弃（丢数据）。
Future<void> _migrateLegacyDatabaseFileName(String dbDirectory) async {
  final File newDb = File(p.join(dbDirectory, fushiDatabaseFileName));
  final File oldDb = File(p.join(dbDirectory, legacyHibikiDatabaseFileName));
  if (await newDb.exists() || !await oldDb.exists()) return;
  try {
    for (final String suffix in <String>['-wal', '-shm', '']) {
      final File src = File('${oldDb.path}$suffix');
      if (await src.exists()) {
        await src.rename('${newDb.path}$suffix');
      }
    }
  } on FileSystemException {
    // 主进程与 `:popup` 进程同时首开时，双方都会进到这里；输家的 rename 会因
    // 源文件已被赢家改走而失败。只要赢家已把主文件改出来，迁移就算完成；
    // 否则是真 IO 故障，照实抛（宁可开库失败也不能静默建空库盖住旧数据）。
    if (!await newDb.exists()) rethrow;
    return;
  }
  debugPrint('[fushi-db] renamed legacy hibiki.db(+sidecars) -> fushi.db '
      'in "$dbDirectory"');
}

LazyDatabase _openDb(String dbDirectory, {bool isMainProcess = true}) {
  return LazyDatabase(() async {
    await _migrateLegacyDatabaseFileName(dbDirectory);
    final file = File(p.join(dbDirectory, fushiDatabaseFileName));
    return _openWithRecovery(file, allowSidecarDelete: isMainProcess);
  });
}

/// Opens an arbitrary `.db` FILE (not a directory). Used by the backup MERGE
/// import (TODO-888) to migrate an extracted backup DB up to the current schema
/// before ATTACHing it to the live DB. Same robust open as [_openDb].
LazyDatabase _openDbFile(String dbFilePath, {bool isMainProcess = true}) {
  return LazyDatabase(() async {
    final file = File(dbFilePath);
    return _openWithRecovery(file, allowSidecarDelete: isMainProcess);
  });
}

/// LWW-element-set 合并结果：[present]=名→加入戳（当前生效标签），[tombstones]=名→移除
/// 戳（移除胜出、需保留墓碑防复活的标签）。
class _MergedTagState {
  const _MergedTagState(this.present, this.tombstones);
  final Map<String, int> present;
  final Map<String, int> tombstones;
}

int _maxInt(int a, int b) => a > b ? a : b;

/// LWW-element-set 逐名裁决：并集两端 add 时钟与墓碑时钟，某标签名 max(addedAt) 严格
/// 大于 max(deletedAt) ⇒ present（否则 removed，含相等——remove-wins on tie，确定性）。
/// present 名清其墓碑（add 戳已持久，未来第三端旧移除仍会被 add 戳压过），removed 名保
/// 留墓碑防复活。
_MergedTagState _mergeTagClocks(
  Map<String, int> localAdded,
  Map<String, int> remoteAdded,
  Map<String, int> localTomb,
  Map<String, int> remoteTomb,
) {
  final Map<String, int> add = <String, int>{...localAdded};
  for (final MapEntry<String, int> e in remoteAdded.entries) {
    add[e.key] =
        add.containsKey(e.key) ? _maxInt(add[e.key]!, e.value) : e.value;
  }
  final Map<String, int> tomb = <String, int>{...localTomb};
  for (final MapEntry<String, int> e in remoteTomb.entries) {
    tomb[e.key] =
        tomb.containsKey(e.key) ? _maxInt(tomb[e.key]!, e.value) : e.value;
  }
  final Map<String, int> present = <String, int>{};
  final Map<String, int> tombstones = <String, int>{};
  for (final String name in <String>{...add.keys, ...tomb.keys}) {
    final int? a = add[name];
    final int? r = tomb[name];
    if (a != null && (r == null || a > r)) {
      present[name] = a;
    } else if (r != null) {
      tombstones[name] = r;
    }
  }
  return _MergedTagState(present, tombstones);
}

@DriftDatabase(tables: [
  MediaItems,
  AnkiMappings,
  SearchHistoryItems,
  Audiobooks,
  AudioCues,
  SrtBooks,
  ReaderPositions,
  Bookmarks,
  ReadingStatistics,
  ReadingHourlyLogs,
  Preferences,
  DictionaryMetadata,
  DictionaryHistory,
  EpubBooks,
  BookTags,
  BookTagMappings,
  SrtBookTagMappings,
  Profiles,
  ProfileSettings,
  MediaTypeProfiles,
  BookProfiles,
  SyncBaselines,
  VideoBooks,
  VideoBookTagMappings,
  VideoWatchStatistics,
  VideoHourlyLogs,
  FavoriteWords,
  MiningStatistics,
  MinedSentences,
  MediaSources,
  Series,
  ShelfEntries,
  MediaCollections,
  MediaCollectionItems,
  CollectionMemberTombstones,
  FushiPairedPeers,
  BookTombstones,
  LookupMiningCounters,
  StatisticsTombstones,
  BookTagMembershipTombstones,
  BookCustomCss,
  CollectionTagMappings,
  SyncDeletionTombstones,
  RevealedImages,
  ActivityEvents,
  ClipboardHistory,
  VideoScrapeMeta,
  CollectionScrapeMeta,
  MediaTrackingMappings,
  MediaTrackingOutbox,
  Galgames,
  GalgameSources,
  GalgameSessions,
  GalgameTagMappings,
  MangaExtensionStores,
  MangaExtensions,
  MangaOnlineSources,
  MangaSourcePreferences,
  MangaTrustedSigners,
  CollectionRelations,
  MediaImages,
])
class FushiDatabase extends _$FushiDatabase {
  /// [isMainProcess] gates the TODO-905 sidecar rebuild: the main app passes
  /// the default `true` (it may physically delete a poisoned `-wal`/`-shm`),
  /// while the separate `:popup` process passes `false` so it backs off on an
  /// IOERR instead of racing the main process to delete the same sidecar.
  FushiDatabase(String dbDirectory, {bool isMainProcess = true})
      : super(_openDb(dbDirectory, isMainProcess: isMainProcess));

  /// Opens a specific `.db` FILE (not a directory). Backup MERGE import
  /// (TODO-888) uses this to migrate an extracted backup DB to the current
  /// schema before merging it into the live DB.
  FushiDatabase.atFile(String dbFilePath, {bool isMainProcess = true})
      : super(_openDbFile(dbFilePath, isMainProcess: isMainProcess));

  FushiDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 69;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from > to) {
            // DOWNGRADE PROTECTION (root-cause fix for the recurring "old app
            // downgrades & destroys the user DB" incidents). drift dispatches
            // onUpgrade whenever the stored user_version != code schemaVersion,
            // INCLUDING when the DB is NEWER than the code (from > to). This is
            // the EARLIEST hook drift gives us, and it runs BEFORE any DROP /
            // migration / customStatement below. We refuse the open here by
            // throwing, which aborts beforeOpen: drift never advances
            // user_version and the DB file is left byte-for-byte intact. NEVER
            // drop / migrate / rebuild in this branch — a previous build did
            // exactly that and wiped users' libraries twice. The app layer
            // catches this exception and shows an "update your app" notice.
            throw FushiDatabaseDowngradeException(
              dbVersion: from,
              appSchemaVersion: to,
            );
          }
          if (from < 2) {
            if (!await _columnExists('dictionary_metadata', 'type')) {
              await m.addColumn(dictionaryMetadata, dictionaryMetadata.type);
            }
          }
          if (from < 3) {
            await m.createTable(readingHourlyLogs);
          }
          if (from < 4) {
            // 历史 v4 加的是 ttu_char_offset；后续 v16 重建仍带它，最终 v24 整列删除
            // （合并到 char_offset）。表定义已无 ttuCharOffset getter，用 raw SQL 保
            // 历史列名，让 v16/v24 找得到它。
            if (!await _columnExists('reader_positions', 'ttu_char_offset')) {
              await customStatement(
                'ALTER TABLE reader_positions '
                'ADD COLUMN ttu_char_offset INTEGER NOT NULL DEFAULT -1',
              );
            }
          }
          if (from < 5) {
            await m.createTable(epubBooks);
          }
          if (from < 6) {
            await m.createTable(bookTags);
            await m.createTable(bookTagMappings);
          }
          if (from < 7) {
            if (!await _columnExists('book_tags', 'sort_order')) {
              await m.addColumn(bookTags, bookTags.sortOrder);
            }
            await customStatement(
              'UPDATE book_tags SET sort_order = id WHERE sort_order = 0',
            );
          }
          if (from < 8) {
            await m.createTable(profiles);
            await m.createTable(profileSettings);
            await m.createTable(mediaTypeProfiles);
            await m.createTable(bookProfiles);
          }
          if (from < 9) {
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_profile_settings_profile ON profile_settings (profile_id)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_media_type_profiles_profile ON media_type_profiles (profile_id)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_book_profiles_profile ON book_profiles (profile_id)',
            );
          }
          if (from < 10) {
            // The book_id orphan cleanup references the legacy `book_id`
            // column. A DB whose book_tag_mappings was created fresh later in
            // this same ladder (via m.createTable with the current v16
            // `book_key` schema) has no `book_id` column, so guard on it — the
            // v16 step re-derives the mapping under `book_key` anyway.
            if (await _columnExists('book_tag_mappings', 'book_id')) {
              await customStatement(
                'DELETE FROM book_tag_mappings '
                'WHERE book_id NOT IN (SELECT id FROM epub_books)',
              );
            }
            await customStatement(
              'DELETE FROM book_tag_mappings '
              'WHERE tag_id NOT IN (SELECT id FROM book_tags)',
            );
            await customStatement(
              'DELETE FROM profile_settings '
              'WHERE profile_id NOT IN (SELECT id FROM profiles)',
            );
            await customStatement(
              'DELETE FROM media_type_profiles '
              'WHERE profile_id NOT IN (SELECT id FROM profiles)',
            );
            await customStatement(
              'DELETE FROM book_profiles '
              'WHERE profile_id NOT IN (SELECT id FROM profiles)',
            );
          }
          if (from < 11) {
            await m.createTable(bookmarks);
            // bookmarks is created via m.createTable using the CURRENT (v16)
            // generated schema (column `book_key`, not legacy `ttu_book_id`),
            // so only create the legacy-named index when that column actually
            // exists. The v16 step recreates it under `book_key`.
            if (await _columnExists('bookmarks', 'ttu_book_id')) {
              await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_bookmarks_ttu_book_id_created '
                'ON bookmarks (ttu_book_id, created_at DESC)',
              );
            }
            await migrateLegacyBookmarkPreferences();
          }
          if (from < 12) {
            Future<bool> tableExists(String name) async {
              final row = await customSelect(
                'SELECT COUNT(*) AS c FROM sqlite_master '
                "WHERE type='table' AND name=?",
                variables: [Variable.withString(name)],
              ).getSingle();
              return row.read<int>('c') > 0;
            }

            // These orphan cleanups reference legacy int columns
            // (ttu_book_id / book_uid). A DB whose tables were created fresh
            // earlier in this ladder uses the v16 `book_key` schema and lacks
            // those columns, so each is additionally column-guarded; the v16
            // step re-runs the equivalent cleanup against `book_key`.
            if (await tableExists('reader_positions') &&
                await tableExists('epub_books') &&
                await _columnExists('reader_positions', 'ttu_book_id')) {
              await customStatement(
                'DELETE FROM reader_positions '
                'WHERE ttu_book_id NOT IN (SELECT id FROM epub_books)',
              );
            }
            // Remove srt_books whose backing epub is gone (standalone SRT
            // books keep ttu_book_id = 0 and are preserved). Run BEFORE the
            // audio_cues cleanup so cues of removed srt_books become orphans.
            if (await tableExists('srt_books') &&
                await tableExists('epub_books') &&
                await _columnExists('srt_books', 'ttu_book_id')) {
              await customStatement(
                'DELETE FROM srt_books '
                'WHERE ttu_book_id > 0 '
                'AND ttu_book_id NOT IN (SELECT id FROM epub_books)',
              );
            }
            // audio_cues.book_uid is owned by EITHER audiobooks.book_uid OR
            // srt_books.uid. Only delete cues orphaned from BOTH owners; the
            // previous audiobooks-only predicate silently wiped every SRT
            // book's cues on upgrade (data loss, HBK-AUDIT-001).
            if (await tableExists('audio_cues') &&
                await tableExists('audiobooks') &&
                await tableExists('srt_books') &&
                await _columnExists('audio_cues', 'book_uid') &&
                await _columnExists('audiobooks', 'book_uid')) {
              await customStatement(
                'DELETE FROM audio_cues '
                'WHERE book_uid NOT IN (SELECT book_uid FROM audiobooks) '
                'AND book_uid NOT IN (SELECT uid FROM srt_books)',
              );
            }
            if (await tableExists('bookmarks') &&
                await tableExists('epub_books') &&
                await _columnExists('bookmarks', 'ttu_book_id')) {
              await customStatement(
                'DELETE FROM bookmarks '
                'WHERE ttu_book_id NOT IN (SELECT id FROM epub_books)',
              );
            }
          }
          if (from < 13) {
            await m.createTable(srtBookTagMappings);
          }
          if (from < 14) {
            // Indexes were previously (re)created in beforeOpen on every open
            // (12 extra sqlite_master probes per launch). Create them once on
            // upgrade so existing DBs gain any missing index; fresh DBs get
            // them in onCreate. This runs on the PRE-v16 schema, so it uses the
            // OLD column names (book_uid / ttu_book_id / book_id). The v16 step
            // below rebuilds those tables and recreates the indexes under the
            // new book_key column names via _ensureIndexes().
            await _ensureLegacyIndexesV14();
          }
          if (from < 15) {
            await m.createTable(syncBaselines);
          }
          if (from < 16) {
            await _migrateBookKeyV16(m);
          }
          if (from < 17) {
            // VideoBooks landed on the name-PK baseline as v17 (the video
            // worktree's original v16-v19 step numbering was rebased onto
            // develop's name-PK v16). develop users never had a video_books
            // table, so a single createTable builds the full schema
            // (book_uid PK + playlist_json / current_episode / audio_track_id /
            // delay_ms). Guard so a fresh DB (which already has the table from
            // onCreate's createAll) doesn't try to recreate it.
            if (!await _tableExists('video_books')) {
              await m.createTable(videoBooks);
            }
          }
          if (from < 20) {
            // Convergence point. The video worktree forked BEFORE develop's
            // name-PK v16 and burned its own v16-v19 numbers on video_books, so
            // a real user DB can sit at user_version 16-19 with epub_books still
            // id-keyed and a legacy id-PK video_books — the from<16 / from<17
            // steps above never fire for it (version already past them). This
            // step converges BOTH lineages by inspecting the ACTUAL schema, not
            // the version number (the two lineages' v16-v19 are semantically
            // different, so only column/PK probes can tell them apart). Both
            // paths are idempotent and lossless for real user data.
            //
            // (1) epub_books still id-keyed (video-line fork never ran name-PK)
            //     -> re-key now. _migrateBookKeyV16 self-guards with
            //     `if (!_columnExists('epub_books','id')) return`, so it is a
            //     no-op for develop name-PK users. It rebuilds books + reading
            //     relations inside one atomic transaction and never touches
            //     video_books (content-keyed, no FK to epub id).
            await _migrateBookKeyV16(m);
            // (2) video_books on the legacy autoincrement id PK (built by the
            //     video line's v16-v19) -> rebuild as book_uid PK. Video data is
            //     reimportable test data, so drop+recreate is simplest and
            //     safest. develop users' video_books (just built by from<17) is
            //     already book_uid-keyed and is left alone.
            if (await _tableExists('video_books') &&
                !await _videoBooksKeyedByBookUid()) {
              await m.deleteTable('video_books');
            }
            if (!await _tableExists('video_books')) {
              await m.createTable(videoBooks);
            }
          }
          if (from < 21) {
            // video_book_tag_mappings: lets video books share the same BookTags
            // pool as EPUB/SRT books. video_books is guaranteed to exist by the
            // from<20 convergence above (FK target). Guard so a fresh DB (table
            // already built by onCreate's createAll) doesn't recreate it.
            if (!await _tableExists('video_book_tag_mappings')) {
              await m.createTable(videoBookTagMappings);
            }
          }
          if (from < 22) {
            // 视频统计：两张独立表 + video_books.completed_at 列。与阅读统计完全
            // 隔离，不碰 reading_statistics。fresh DB 已由 onCreate 的 createAll
            // 建好，故用 _tableExists / _columnExists 守卫避免重复创建。
            if (!await _tableExists('video_watch_statistics')) {
              await m.createTable(videoWatchStatistics);
            }
            if (!await _tableExists('video_hourly_logs')) {
              await m.createTable(videoHourlyLogs);
            }
            if (!await _columnExists('video_books', 'completed_at')) {
              await m.addColumn(videoBooks, videoBooks.completedAt);
            }
          }
          if (from < 23) {
            // 收藏词条 + 制卡计数：查词弹窗收藏与制卡计入阅读/视频统计。fresh DB
            // 已由 onCreate 的 createAll 建好，用 _tableExists 守卫避免重复创建。
            if (!await _tableExists('favorite_words')) {
              await m.createTable(favoriteWords);
            }
            if (!await _tableExists('mining_statistics')) {
              await m.createTable(miningStatistics);
            }
          }
          if (from < 24) {
            // BUG-162: 阅读位置精确字符偏移合并为单一列 char_offset，删除原
            // ttu_char_offset（sync 精确缓存列——云同步精度退化为 normCharOffset 分数后
            // 不再需要）。用 ADD/DROP COLUMN（与表里其他列名无关，避免依赖 book_key 是否
            // 已 re-key；SQLite 3.35+ 支持 DROP COLUMN，bundled sqlite3 够新）。既有行
            // char_offset 默认 -1（首次退出再进回退分数，翻一页 re-save 即精确）。
            // partial 测试 DB 无此表 → _tableExists 守卫跳过。
            if (await _tableExists('reader_positions')) {
              if (!await _columnExists('reader_positions', 'char_offset')) {
                await customStatement(
                  'ALTER TABLE reader_positions '
                  'ADD COLUMN char_offset INTEGER NOT NULL DEFAULT -1',
                );
              }
              if (await _columnExists('reader_positions', 'ttu_char_offset')) {
                await customStatement(
                  'ALTER TABLE reader_positions DROP COLUMN ttu_char_offset',
                );
              }
            }
          }
          if (from < 25) {
            // 制卡历史：逐条制卡记录（句子 + 跳回原文的定位锚点），供收藏夹页全局查看。
            // fresh DB 已由 onCreate 的 createAll 建好，用 _tableExists 守卫避免重复创建。
            if (!await _tableExists('mined_sentences')) {
              await m.createTable(minedSentences);
            }
          }
          if (from < 26) {
            // TODO-809 自愈回填：历史（BUG-414 修复前）sync/导入侧用
            // sanitizeTtuFilename(title) 重算 audiobook 的 book_key 而非 host 真实
            // key 写库，导致 audiobooks.book_key 与 epub_books.book_key 集体失配 →
            // 书架耳机徽章判据（audiobooks.book_key == epub_books.book_key 纯字符串
            // 相等）查不中，有声书集体「变成普通书」。写入侧已彻底修干净，但已落库的
            // 失配旧行永远查不中，故需一次性安全回填。详见
            // backfillMismatchedAudiobookKeysV26 的契约说明。
            await backfillMismatchedAudiobookKeysV26();
          }
          if (from < 27) {
            // TODO-817 网络/本地来源库地基：新增 media_sources 表 + video_books /
            // epub_books 的 source_id 外键列（onDelete:setNull）。无损迁移：只
            // createTable + addColumn（nullable 无 default → 既有行 source_id 全
            // NULL），不 DROP / 不改既有列 / 不删行。守卫幂等（fresh DB 已由 onCreate
            // 的 createAll 建好，重复升级 no-op）。**顺序必须先 createTable(mediaSources)
            // 再两 addColumn**（FK 目标表须先存在；SQLite ADD COLUMN 带 REFERENCES 仅
            // 当新列默认 NULL 时合法，sourceId nullable 无 default 满足）。
            if (!await _tableExists('media_sources')) {
              await m.createTable(mediaSources);
            }
            if (await _tableExists('video_books') &&
                !await _columnExists('video_books', 'source_id')) {
              await m.addColumn(videoBooks, videoBooks.sourceId);
            }
            if (await _tableExists('epub_books') &&
                !await _columnExists('epub_books', 'source_id')) {
              await m.addColumn(epubBooks, epubBooks.sourceId);
            }
          }
          if (from < 28) {
            // TODO-857 视频双字幕（Path A）：video_books 加 secondary_subtitle_source。
            // 无损迁移：只 addColumn（nullable 无 default → 既有行全 NULL = 无副字幕），
            // 不 DROP / 不改既有列 / 不删行。守卫幂等（fresh DB 已由 onCreate 的
            // createAll 建好，用 _columnExists 守卫避免重复加列，重复升级 no-op）。
            if (await _tableExists('video_books') &&
                !await _columnExists(
                    'video_books', 'secondary_subtitle_source')) {
              await m.addColumn(videoBooks, videoBooks.secondarySubtitleSource);
            }
          }
          if (from < 29) {
            // TODO-894：自愈 EPUB-backed 有声书缺失的配对 srt_books 行。历史上
            // _importEpubWithAlignment 只写 audiobooks，不写 srt_books → push 两条
            // 消费路径（live push + syncAudiobookPackages）查 getSrtBookByBookKey
            // ==null → 整本永不上传。本步只 INSERT 缺失的配对行（不改既有列/不删行）。
            await backfillMissingAudiobookSrtBooksV29();
          }
          if (from < 30) {
            // TODO-616 B 排序 + A 合集：新建 series + shelf_entries 两张映射表。
            // 无损迁移：只 createTable，不 DROP / 不改列 / 不删行 / 不回填行（旧库
            // 升级后两表空 = 默认散书 + sortOrder 退化 importedAt 倒序，Never break
            // userspace）。顺序：先 series（shelf_entries.seriesId 外键目标）再
            // shelf_entries。守卫幂等（fresh DB 已由 onCreate 的 createAll 建好，用
            // _tableExists 守卫避免重复创建，重复升级 no-op）。
            if (!await _tableExists('series')) {
              await m.createTable(series);
            }
            if (!await _tableExists('shelf_entries')) {
              await m.createTable(shelfEntries);
            }
          }
          if (from < 31) {
            // TODO-1017 阶段1：互联 per-peer 授权凭据表（历史上以旧名
            // hibiki_paired_peers 建出；v69 起统一为 fushi_paired_peers）。无损
            // 迁移：只 createTable，不 DROP / 不改列 / 不删行 / 不回填行（旧库升级
            // 后此表空 = 无已配对对端 = auth 接线未开启前行为零变化，Never break
            // userspace）。守卫幂等（fresh DB 已由 onCreate 的 createAll 建好，用
            // _tableExists 守卫避免重复创建，重复升级 no-op）。注意 drift 迁移步
            // 永远按**当前** Dart 表定义建表（本文件既有惯例），所以从 <31 一路
            // 升上来的库在这里直接建出 v69 的新名 fushi_paired_peers，下面的 v69
            // 改名步对它天然 no-op。
            if (!await _tableExists('fushi_paired_peers')) {
              await m.createTable(fushiPairedPeers);
            }
          }
          if (from < 32) {
            // TODO-1195 part B：已删书墓碑表 book_tombstones。无损迁移：只
            // createTable，不 DROP / 不改列 / 不删行 / 不回填行（旧库升级后此表空 =
            // 无墓碑 = 合并导入行为零变化，Never break userspace）。守卫幂等（fresh DB
            // 已由 onCreate 的 createAll 建好，用 _tableExists 守卫避免重复创建）。
            if (!await _tableExists('book_tombstones')) {
              await m.createTable(bookTombstones);
            }
          }
          if (from < 33) {
            // TODO-1204：查词 / 制卡 per-book 计数表 lookup_mining_counters。无损
            // 迁移：只 createTable，不 DROP / 不改列 / 不删行 / 不回填行（旧库升级后
            // 此表空 = 查词/制卡历史计数从 0 起，与旧行为一致，Never break userspace）。
            // 守卫幂等（fresh DB 已由 onCreate 的 createAll 建好，用 _tableExists 守卫
            // 避免重复创建，重复升级 no-op）。
            if (!await _tableExists('lookup_mining_counters')) {
              await m.createTable(lookupMiningCounters);
            }
          }
          if (from < 34) {
            // TODO-1204 后续：per-book/video 统计删除墓碑表 statistics_tombstones。
            // 无损迁移：只 createTable，不 DROP / 不改列 / 不删行 / 不回填行（旧库升级
            // 后此表空 = 无统计墓碑 = 云同步 / 备份合并跳过逻辑零命中 = 行为与旧版一致，
            // Never break userspace）。守卫幂等（fresh DB 已由 onCreate 的 createAll
            // 建好，用 _tableExists 守卫避免重复创建，重复升级 no-op）。
            if (!await _tableExists('statistics_tombstones')) {
              await m.createTable(statisticsTombstones);
            }
          }
          if (from < 35) {
            // TODO-1157：video_books 加 stream_spec_json，让「粘贴 URL 导入」的流媒体
            // 像本地视频一样入库、在书架持久、可重复打开（重开时据此重建流客户端）。
            // 无损迁移：只 addColumn（nullable 无 default → 既有行全 NULL = 本地视频，
            // 不改既有列 / 不删行）。守卫幂等（fresh DB 已由 onCreate 的 createAll 建好，
            // 用 _columnExists 守卫避免重复加列，重复升级 no-op）。
            if (await _tableExists('video_books') &&
                !await _columnExists('video_books', 'stream_spec_json')) {
              await m.addColumn(videoBooks, videoBooks.streamSpecJson);
            }
          }
          if (from < 36) {
            // TODO-1252：favorite_words 加 book_key / title，让收藏能按书 / 视频归属，
            // 供统计页 per-book/video tile 展示「收藏 N」（对齐查词 / 制卡 tile）。
            // 无损迁移：只 addColumn（book_key nullable 无 default、title 有默认空串 →
            // 既有行 book_key=NULL / title='' = 无书归属 = 只进汇总不落 tile，不改既有列 /
            // 不删行，uniqueKey 不变 = 汇总计数 / 同步契约零变化，Never break userspace）。
            // 守卫幂等（fresh DB 已由 onCreate 的 createAll 建好，用 _columnExists 守卫
            // 避免重复加列，重复升级 no-op）。
            if (await _tableExists('favorite_words')) {
              if (!await _columnExists('favorite_words', 'book_key')) {
                await m.addColumn(favoriteWords, favoriteWords.bookKey);
              }
              if (!await _columnExists('favorite_words', 'title')) {
                await m.addColumn(favoriteWords, favoriteWords.title);
              }
            }
          }
          if (from < 37) {
            // TODO-1288：再跑一次 EPUB-backed 有声书 srt_books self-heal backfill。
            // v29 的一次性 backfill 只在「升级跨过 29」时执行；而
            // audiobook_import_dialog 给已有 EPUB 书加/换音频的路径在 TODO-1288 之前
            // 一直漏写配对 srt_books 行，故 v29 之后（DB 已 ≥29）经该对话框新导入的
            // EPUB-backed 有声书重新变回「无配对 SrtBook」——互联 host 认不出（显示成
            // 普通书 + 音频永不同步）。导入路径已在 TODO-1288 补写；此处对已存的历史
            // 破损数据补一次自愈。backfillMissingAudiobookSrtBooksV29 幂等
            // （NOT IN + INSERT OR IGNORE），重复运行 no-op，standalone 字幕书无
            // audiobooks 行天然豁免，Never break userspace。
            await backfillMissingAudiobookSrtBooksV29();
          }
          if (from < 38) {
            // 统一合集（Jellyfin BoxSet/Playlist 式）：新建 media_collections +
            // media_collection_items 引用表；把旧 [Series] 转成 collection；把每条多集
            // playlist video_books 行拆成 N 条独立集行 + 一个 playlist 合集（含
            // mined_sentences / favorite_sentences 集坐标改写，使拆集后旧收藏/制卡跳转
            // 仍指向正确的集）。建表无损（只 createTable，_tableExists 守卫幂等）；数据
            // 改写由 from<38 门槛保证**单次**执行（fresh DB 走 onCreate.createAll，不进
            // 此分支）。拆集 + 删 parent 是破坏性改写但可测（migration_v38_collections_
            // test），且属 feature 分支未发布，用户升级只跑一次。
            if (!await _tableExists('media_collections')) {
              await m.createTable(mediaCollections);
            }
            if (!await _tableExists('media_collection_items')) {
              await m.createTable(mediaCollectionItems);
            }
            // 顺序要点：先拆多集，再转系列。拆集会删掉多集 playlist 的 parent
            // shelf_entry；若该 playlist 曾归入某系列，系列转换随后就不再把它当成员
            // （拆出的 playlist 合集提到顶层、原系列失去该成员——计划非目标「不做嵌套
            // 合集」的既定行为），避免系列 collection 留悬空成员 / 剧集丢归属。
            await splitPlaylistVideoBooksV38();
            await migrateSeriesToCollectionsV38();
          }
          if (from < 39) {
            // v39：VideoWatchStatistics 加 book_uid，根治同名视频统计互串（旧表按
            // (title,dateKey) 唯一键控，两个同名视频写同一行）。alterTable 按当前
            // Dart 定义重建表（唯一键换成 (book_uid,date_key)，NULL 互异不冲突），
            // 再按 title 唯一匹配回填 book_uid；同名多视频保持 NULL（读取端按
            // title 回退，不误配）。_tableExists 守卫：极老库/最小测试库可能尚无
            // 此表（幂等防御，风格同 v38 块）。
            if (await _tableExists('video_watch_statistics')) {
              await m.alterTable(TableMigration(
                videoWatchStatistics,
                newColumns: [videoWatchStatistics.bookUid],
              ));
              await customStatement(
                'UPDATE video_watch_statistics SET book_uid = ('
                ' SELECT vb.book_uid FROM video_books vb'
                ' WHERE vb.title = video_watch_statistics.title'
                ' AND NOT EXISTS (SELECT 1 FROM video_books vb2'
                '  WHERE vb2.title = vb.title'
                '  AND vb2.book_uid != vb.book_uid)'
                ') WHERE book_uid IS NULL',
              );
            }
          }
          if (from < 40) {
            // v40（多端库联合视图 §2.3 任务1）：合集跨端同步地基。
            // ① media_collections 加 order_updated_at（默认 0 = 从未手动排序——任何
            //    真实改序时间戳都能盖过它，跨端手动序整合集 LWW 的比较键）；
            // ② 新表 collection_member_tombstones（成员移出墓碑 + 空哨兵行 = 合集级
            //    删除墓碑，防并集同步复活）。
            // 无损迁移：只 addColumn + createTable，不 DROP / 不改行 / 不回填（旧库
            // 升级后列全 0、表全空 = 同步合并零命中 = 行为与旧版一致，Never break
            // userspace）。守卫幂等（fresh DB 已由 onCreate 的 createAll 建好，
            // _tableExists/_columnExists 守卫避免重复创建，重复升级 no-op）。
            if (await _tableExists('media_collections') &&
                !await _columnExists('media_collections', 'order_updated_at')) {
              await m.addColumn(
                  mediaCollections, mediaCollections.orderUpdatedAt);
            }
            if (!await _tableExists('collection_member_tombstones')) {
              await m.createTable(collectionMemberTombstones);
            }
          }
          if (from < 41) {
            // v41（tags 稳健档跨端同步 LWW-element-set）：
            // ① book_tag_mappings / video_book_tag_mappings 加 added_at（默认 0 =
            //    最古 add，任何带时间戳的远端移除都能压过它做 remove-wins 裁决）；
            // ② 新表 book_tag_membership_tombstones（标签移除墓碑，防并集同步复活）。
            // 无损迁移：只 addColumn + createTable，不 DROP / 不回填（旧库升级后
            // added_at 全 0、墓碑表空 = sync 合并与旧版 additive 行为等价，Never break
            // userspace）。守卫幂等（fresh DB 走 onCreate.createAll）。
            if (await _tableExists('book_tag_mappings') &&
                !await _columnExists('book_tag_mappings', 'added_at')) {
              await m.addColumn(bookTagMappings, bookTagMappings.addedAt);
            }
            if (await _tableExists('video_book_tag_mappings') &&
                !await _columnExists('video_book_tag_mappings', 'added_at')) {
              await m.addColumn(
                  videoBookTagMappings, videoBookTagMappings.addedAt);
            }
            if (!await _tableExists('book_tag_membership_tombstones')) {
              await m.createTable(bookTagMembershipTombstones);
            }
          }
          if (from < 42) {
            // v42（per-book CSS 跨端同步）：新表 book_custom_css（bookKey+relativePath →
            // content + deleted + updatedAt，LWW 时间戳载体）。无损迁移：只 createTable，
            // 旧库升级后空表 = sync 零命中 = 行为与旧版一致（Never break userspace）。
            if (!await _tableExists('book_custom_css')) {
              await m.createTable(bookCustomCss);
            }
          }
          if (from < 43) {
            // v43（合集打标签）：新表 collection_tag_mappings（collectionId+tagId →
            // 复用 BookTags 标签池的 M:N 关联）。无损迁移：只 createTable，旧库升级后
            // 空表 = sync 零命中 = 行为与旧版一致（Never break userspace）。守卫幂等
            // （fresh DB 已由 onCreate 的 createAll 建好）。
            if (!await _tableExists('collection_tag_mappings')) {
              await m.createTable(collectionTagMappings);
            }
          }
          if (from < 44) {
            // v44（显式确认式删除传播）：新表 sync_deletion_tombstones（mediaType+itemKey →
            // deletedAt + remotePublishedAt）。无损迁移：只 createTable，旧库升级后空表 =
            // 无墓碑 = 删除不传播（与旧 union-only 行为一致，Never break userspace）。
            if (!await _tableExists('sync_deletion_tombstones')) {
              await m.createTable(syncDeletionTombstones);
            }
          }
          if (from < 45) {
            // v45（合集字幕批量下载）：media_collections 加 anilist_id（合集↔AniList 系列
            // 绑定，为「为整个合集获取字幕」快照 anilist_id、跳过逐集番名猜测）。无损迁移：
            // 只 addColumn（nullable 无 default → 既有行全 NULL = 未绑定 = 回退合集名现解析，
            // Never break userspace）。守卫幂等（fresh DB 已由 onCreate 建好）。
            if (await _tableExists('media_collections') &&
                !await _columnExists('media_collections', 'anilist_id')) {
              await m.addColumn(mediaCollections, mediaCollections.anilistId);
            }
          }
          if (from < 46) {
            // v46（书「完成」状态）：epub_books 加 completed_at（镜像
            // video_books.completed_at）。用户手动「标记为已读完」或读到全书末尾时写入
            // 时间戳，null = 未完成，书架概览「Completed」统计据此计数（不再只靠「读到
            // 最后一字」的临时派生，跳过后记/附录也能手动计入）。有声书共用同一列——其
            // 配对 EpubBooks 行的 bookKey 是唯一完成真值（有声书阅读会话 widget.bookKey
            // 即该 bookKey），故无需给 srt_books 另立一列。无损迁移：只 addColumn
            // （nullable 无 default → 既有行全 NULL = 未完成 = 与旧行为一致，Never break
            // userspace）。守卫幂等（fresh DB 已由 onCreate 建好，重复升级 no-op）。
            if (await _tableExists('epub_books') &&
                !await _columnExists('epub_books', 'completed_at')) {
              await m.addColumn(epubBooks, epubBooks.completedAt);
            }
          }
          if (from < 47) {
            // v47（图片防剧透遮罩揭开状态持久化 + 书内↔图片库双向同步，BUG-898）：新表
            // revealed_images（bookKey+imageKey → revealedAt）。无损迁移：只 createTable，
            // 旧库升级后空表 = 全部图片保持遮罩 = 行为与旧版一致（Never break userspace）。
            // 守卫幂等（fresh DB 已由 onCreate 的 createAll 建好）。
            if (!await _tableExists('revealed_images')) {
              await m.createTable(revealedImages);
            }
          }
          if (from < 48) {
            // BUG-906 (B): hot-path indexes added to [_ensureIndexes] (audio_cues
            // composite, tag_id on the three tag-mapping tables, favorite_words
            // source_type). Fresh DBs get them via onCreate; existing DBs only
            // pick them up through this once-per-DB upgrade step. This mirrors
            // the sanctioned index-migration pattern established by HBK-AUDIT-094
            // (indexes live in onCreate + a versioned onUpgrade step, NOT in
            // beforeOpen-every-launch which that audit deliberately removed).
            // _ensureIndexes is fully idempotent (CREATE INDEX IF NOT EXISTS,
            // table-existence guarded), so re-running it here is a safe no-op for
            // the already-present indexes and only creates the new ones.
            await _ensureIndexes();
          }
          if (from < 49) {
            // v49（首页活动时间轴）：新表 activity_events（精确时间戳的事件流，喂新
            // 首页 Activity 面板）。无损迁移：只 createTable，旧库升级后空表 = 首页
            // Activity 为空、历史阅读/观看仍在按天统计表里可查（Never break
            // userspace）。守卫幂等（fresh DB 已由 onCreate 的 createAll 建好），
            // 建表后补 _ensureIndexes 建 timestamp 索引。
            if (!await _tableExists('activity_events')) {
              await m.createTable(activityEvents);
            }
            await _ensureIndexes();
          }
          if (from < 50) {
            // v50（桌面剪贴板复制历史，弹窗历史按钮）：新表 clipboard_history。无损迁移：
            // 只 createTable，旧库升级后空表 = 历史按钮暂无内容。守卫幂等（fresh DB 已由
            // onCreate 的 createAll 建好）。
            if (!await _tableExists('clipboard_history')) {
              await m.createTable(clipboardHistory);
            }
          }
          if (from < 51) {
            // v51（PDF 阅读器 Phase 1）：epub_books 加 format 判别列（'epub'/'pdf'），
            // 把 PDF 当「第二种书」复用整套书架/进度/删除管线而非另建平行表。无损迁移：
            // 列 withDefault('epub') → SQLite ADD COLUMN 自动把既有全部行回填 'epub'，
            // 行为与旧版完全一致（Never break userspace）。守卫幂等（fresh DB 已由
            // onCreate 的 createAll 建好，重复升级 _columnExists 短路 no-op）。
            if (await _tableExists('epub_books') &&
                !await _columnExists('epub_books', 'format')) {
              await m.addColumn(epubBooks, epubBooks.format);
            }
          }
          if (from < 52) {
            // v52（恢复同系列音轨/字幕调轴记忆，回归修复）：media_collections 加
            // audio_track_id + subtitle_delay_ms 两列，把统一合集迁移前「多集共享
            // 一行 VideoBooks」天然拥有的系列级音轨/调轴偏好提升回系列容器（迁移后
            // 每集独立行 → 换集丢记忆）。无损迁移：两列 nullable 无 default → 既有行
            // 全 NULL = 系列内没人设过 = 加载回退各集 per-book 值 / 旧行为（Never
            // break userspace）。守卫幂等（fresh DB 已由 onCreate 建好，重复升级
            // _columnExists 短路 no-op）。
            if (await _tableExists('media_collections')) {
              if (!await _columnExists('media_collections', 'audio_track_id')) {
                await m.addColumn(
                    mediaCollections, mediaCollections.audioTrackId);
              }
              if (!await _columnExists(
                  'media_collections', 'subtitle_delay_ms')) {
                await m.addColumn(
                    mediaCollections, mediaCollections.subtitleDelayMs);
              }
            }
          }
          if (from < 53) {
            // v53（漫画 OCR，第三种书）：epub_books 加 manga_reading_mode 覆盖列
            // （null=按页图长宽比自动判定 / 'spread' / 'webtoon'）。把漫画当「第三种书」
            // 复用整套书架/进度/删除管线而非另建平行表。无损迁移：列 nullable → SQLite
            // ADD COLUMN 把既有全部行回填 NULL（= 自动判定，行为对非漫画书无影响，
            // Never break userspace）。守卫幂等（fresh DB 已由 onCreate 的 createAll
            // 建好，重复升级 _columnExists 短路 no-op）。
            if (await _tableExists('epub_books') &&
                !await _columnExists('epub_books', 'manga_reading_mode')) {
              await m.addColumn(epubBooks, epubBooks.mangaReadingMode);
            }
          }
          if (from < 54) {
            // v54（视频条目刮削「抄 Bangumi」）：新建 video_scrape_meta 存条目级
            // 资料（简介/评分/放送/话数/标签/infobox）。纯新增表，不动任何既有表
            // 或列——旧库升级后该表为空 = 全部未刮削，自动刮削逐步回填，既有封面/
            // 进度/字幕行为完全不变（Never break userspace）。守卫幂等（fresh DB 已由
            // onCreate 的 createAll 建好，重复升级 _tableExists 短路 no-op）。
            if (!await _tableExists('video_scrape_meta')) {
              await m.createTable(videoScrapeMeta);
            }
          }
          if (from < 55) {
            // v55（游戏库对齐 ReinaManager）：新表 galgames / galgame_sources /
            // galgame_sessions，把 galgame 游戏库从偏好表单一 JSON key
            // `galgame_library` 提升为真正的表（旧的 6 字段列表撑不起元数据、
            // 游玩状态与排序筛选）。
            //
            // 无损迁移：建表后把旧 JSON 逐条回填进 galgames（playStatus=0=未设置，
            // 元数据列全 null = 尚未刮削 → 展示回落到本地 name + 默认图标，与旧版
            // 观感完全一致，Never break userspace）。
            //
            // 刻意**不删**偏好里的 `galgame_library`：降级已被 beforeOpen 守卫挡住，
            // 保留它作为回滚兜底。该 key 自 v55 起是 legacy，只在本次迁移读一次，
            // 新代码一律读表。
            if (!await _tableExists('galgames')) {
              await m.createTable(galgames);
            }
            if (!await _tableExists('galgame_sources')) {
              await m.createTable(galgameSources);
            }
            if (!await _tableExists('galgame_sessions')) {
              await m.createTable(galgameSessions);
            }
            await _backfillGalgamesFromPreferences();
            await _ensureIndexes();
          }
          if (from < 56) {
            // v56（可配置游戏启动参数）：galgames 加 launch_args 列，存用户为该游戏
            // 配置的整行命令行参数（启动时按 Windows 规则拆成 argv，逐个经 injector
            // 的 `--arg` 透传给游戏 exe）。
            //
            // 无损迁移：列带 DEFAULT ''，SQLite ADD COLUMN 把既有全部行回填空串
            // = 不带任何参数 = 与旧版逐字节相同的启动命令行（Never break userspace）。
            // 守卫幂等（fresh DB 已由 onCreate 的 createAll 建好，重复升级
            // _columnExists 短路 no-op）。
            if (await _tableExists('galgames') &&
                !await _columnExists('galgames', 'launch_args')) {
              await m.addColumn(galgames, galgames.launchArgs);
            }
          }
          if (from < 57) {
            // v57（命名统一 Phase 4）：三项低风险持久化统一，纯改名/改型无语义变化。
            // ① video_book_tag_mappings.video_book_uid → book_uid（外键列与被引列
            //    [VideoBooks].bookUid 同名，消同表内异名）；
            // ② collection_member_tombstones / book_tag_membership_tombstones 的
            //    removed_at → deleted_at（注释自承语义即 deletedAt，与 BookTombstones
            //    等其余墓碑表对齐；sync 清单 wire JSON 的 `removedAt` 键冻结不动）；
            // ③ video_books.imported_at：drift DateTime（Unix 秒存储）→ int 毫秒戳
            //    （对齐 EpubBooks/SrtBooks/MediaItems 的 int 毫秒范式）。×1000 无损
            //    转换（NULL 保持 NULL）；本步之前的 ladder（如 v38 拆集）在旧库上
            //    仍按秒读写该列，时序正确。
            // ①② 列 rename 用 alterTable 按当前 Dart 定义重建表、columnTransformer
            // 搬旧列（v39 先例）；③ 不重建——drift DateTime 与 int 同为 INTEGER 存储，
            // 物理 schema 零变化，纯 UPDATE ×1000 即可（也避免整表复制对极老/最小
            // 种子库缺列的脆弱性）。FK OFF/ON 夹整块（v16 先例）：重建
            // video_book_tag_mappings 期间不触发其对 video_books/book_tags 的 FK。
            // 守卫幂等：mid-ladder 由 m.createTable fresh 建出的表已是新 shape，
            // _columnExists 短路 no-op。
            await customStatement('PRAGMA foreign_keys = OFF');
            try {
              if (await _tableExists('video_book_tag_mappings') &&
                  await _columnExists(
                      'video_book_tag_mappings', 'video_book_uid')) {
                await m.alterTable(TableMigration(
                  videoBookTagMappings,
                  columnTransformer: {
                    videoBookTagMappings.bookUid:
                        const CustomExpression<String>('video_book_uid'),
                  },
                ));
              }
              if (await _tableExists('collection_member_tombstones') &&
                  await _columnExists(
                      'collection_member_tombstones', 'removed_at')) {
                await m.alterTable(TableMigration(
                  collectionMemberTombstones,
                  columnTransformer: {
                    collectionMemberTombstones.deletedAt:
                        const CustomExpression<int>('removed_at'),
                  },
                ));
              }
              if (await _tableExists('book_tag_membership_tombstones') &&
                  await _columnExists(
                      'book_tag_membership_tombstones', 'removed_at')) {
                await m.alterTable(TableMigration(
                  bookTagMembershipTombstones,
                  columnTransformer: {
                    bookTagMembershipTombstones.deletedAt:
                        const CustomExpression<int>('removed_at'),
                  },
                ));
              }
              if (await _tableExists('video_books') &&
                  await _columnExists('video_books', 'imported_at')) {
                // 秒 → 毫秒；NULL 行不动（无导入时间的旧数据保持未知，不造假时间）。
                await customStatement(
                  'UPDATE video_books SET imported_at = imported_at * 1000 '
                  'WHERE imported_at IS NOT NULL',
                );
              }
              // 完整性门：重建过的映射表跑 foreign_key_check——有悬空引用说明
              // 搬数据出错，宁抛（回滚本次打开）不放行坏库。_tableExists 守卫：
              // 极老/最小种子库可能没有此表（对不存在的表跑该 PRAGMA 直接报错）；
              // 父表 video_books/book_tags 缺失的最小种子库同样跳过（该 PRAGMA
              // 要求父表在场，真实旧库两张父表恒存在）。
              if (await _tableExists('video_book_tag_mappings') &&
                  await _tableExists('video_books') &&
                  await _tableExists('book_tags')) {
                final List<QueryRow> violations = await customSelect(
                        'PRAGMA foreign_key_check(video_book_tag_mappings)')
                    .get();
                if (violations.isNotEmpty) {
                  throw StateError(
                      'v57 migration left ${violations.length} FK violations '
                      'in video_book_tag_mappings');
                }
              }
            } finally {
              await customStatement('PRAGMA foreign_keys = ON');
            }
          }
          if (from < 58) {
            // v58：外部媒体自动记录。两张新表只追加、不改写任何既有书/视频/进度：
            // mapping 保存稳定的 Bangumi 映射，outbox 保存离线可恢复的单调进度队列。
            // 先建父表再建带 FK 的队列表；fresh DB 由 createAll 一次建齐。
            if (!await _tableExists('media_tracking_mappings')) {
              await m.createTable(mediaTrackingMappings);
            }
            if (!await _tableExists('media_tracking_outbox')) {
              await m.createTable(mediaTrackingOutbox);
            }
          }
          if (from < 59) {
            // v59（BUG-1113「游戏没有标签」）：把游戏接进共享 BookTags 标签池。
            // 纯新增映射表；游戏与标签均为本机局域数据，不进入 live-sync。
            if (!await _tableExists('galgame_tag_mappings')) {
              await m.createTable(galgameTagMappings);
            }
            await _ensureIndexes();
          }
          if (from < 60) {
            // v60：漫画/PDF 的「页数」维度。字数与页数是两个独立量纲，页数绝不塞进
            // charactersRead（会污染字数口径与阅读速度）。旧行补默认 0。
            // 表/列存在性双守卫：从 v1 起的完整迁移阶梯里 reading_statistics 可能
            // 尚未建（早期版本没这张表），而某些路径下它是以最新定义建的（已含本列）。
            if (await _tableExists('reading_statistics') &&
                !await _columnExists('reading_statistics', 'pages_read')) {
              await m.addColumn(readingStatistics, readingStatistics.pagesRead);
            }
          }
          if (from < 61) {
            // v61（BUG-1211「改的是合集封面，不是每一集的封面」）：media_collections
            // 加 cover_path 列 = 合集**自有**封面图的绝对路径。
            //
            // 纯 ADD COLUMN，不重建表、不动任何既有行、零 DROP。列 nullable 且无
            // DEFAULT → SQLite 把既有全部行回填 NULL；渲染端 NULL 时继续走旧的
            // 「遍历成员借第一张封面」链，老合集封面逐像素不变（Never break userspace）。
            // 守卫幂等：fresh DB 已由 onCreate 的 createAll 建好，重复升级
            // _columnExists 短路 no-op。
            if (await _tableExists('media_collections') &&
                !await _columnExists('media_collections', 'cover_path')) {
              await m.addColumn(mediaCollections, mediaCollections.coverPath);
            }
          }
          if (from < 62) {
            // v62（每游戏窗口超分档位）：galgames 加 upscaling_mode 列，存该游戏的
            // Magpie 超分档位（'auto' / 'installed_only' / 'off'）。与 v56 的
            // launch_args 同型：都是「用户为该游戏设的启动期配置」。
            //
            // 无损迁移：列带 DEFAULT ''，SQLite ADD COLUMN 把既有全部行回填空串
            // = 用户没设过 = 解析层回落到关闭（老用户绝不会被莫名打开超分，
            // Never break userspace）。守卫幂等（fresh DB 已由 onCreate 的 createAll
            // 建好，重复升级 _columnExists 短路 no-op）。
            if (await _tableExists('galgames') &&
                !await _columnExists('galgames', 'upscaling_mode')) {
              await m.addColumn(galgames, galgames.upscalingMode);
            }
          }
          if (from < 63) {
            // v63：删除已废弃的 galgame 全局窗口超分偏好。v62 起超分档位的
            // 唯一真值是 galgames.upscaling_mode；旧 KV 既不能映射成任一游戏，
            // 也不能留在 Profile 快照里等切换 Profile 时复活。
            //
            // 两张表的清理必须同成同败：onUpgrade 本身不保证把多个裸 SQL 包成
            // 一个事务，因此这里显式 transaction。第二条 DELETE 若因损坏的历史
            // schema 失败，第一条也回滚，user_version 仍停在旧版本供修复后重试。
            // 成功后不留影子副本——这是用户明确要求的不可逆数据删除。
            const String obsoleteKey = 'galgame_magpie_upscaling_mode';
            await transaction(() async {
              if (await _tableExists('preferences')) {
                await customStatement(
                  'DELETE FROM preferences WHERE key = ?',
                  <Object?>[obsoleteKey],
                );
              }
              if (await _tableExists('profile_settings')) {
                await customStatement(
                  'DELETE FROM profile_settings '
                  "WHERE category = 'pref' AND key = ?",
                  <Object?>[obsoleteKey],
                );
              }
            });
          }
          if (from < 64) {
            // v64（BUG-1310）：新增 collection_scrape_meta —— 合集级刮削资料的
            // 宿主。此前元数据只有 video_scrape_meta（主键 bookUid）这一个宿主，
            // 而简介/评分/放送/标签属于「一部作品」= 合集，于是合集刮削只能下一张
            // 海报就结束，详情页除标题和进度外一片空白。
            //
            // 纯新增表，不动任何既有表/列：旧库升级后本表为空 = 全部合集未刮削，
            // 详情页回落到「只有标题 + 进度」的旧形态，逐像素不变（Never break
            // userspace）；用户重刮一次即回填。
            //
            // 幂等：fresh DB 已由 onCreate 的 createAll 建好，重复升级时
            // _tableExists 短路 no-op。
            if (!await _tableExists('collection_scrape_meta')) {
              await m.createTable(collectionScrapeMeta);
            }
          }
          if (from < 65) {
            // v65（Mihon 漫画扩展生态）：全是独立新表，不改写现有漫画/书架/
            // 来源扫描数据。旧用户升级后五张表为空，表现为「尚未添加扩展仓库」。
            //
            // 号位说明：本迁移在 PR 分支上先后写作 v63 / v64，两次都与 develop
            // 上已落地的迁移撞号（v63 = 删除废弃的 galgame 全局超分偏好，
            // v64 = collection_scrape_meta）。三条迁移互不相干且都必须执行，
            // 故本条顺延到 v65 排在最后。建表全部由 _tableExists 守卫，幂等，
            // 且与 v63 / v64 之间没有顺序耦合。
            if (!await _tableExists('manga_extension_stores')) {
              await m.createTable(mangaExtensionStores);
            }
            if (!await _tableExists('manga_extensions')) {
              await m.createTable(mangaExtensions);
            }
            if (!await _tableExists('manga_online_sources')) {
              await m.createTable(mangaOnlineSources);
            }
            if (!await _tableExists('manga_source_preferences')) {
              await m.createTable(mangaSourcePreferences);
            }
            if (!await _tableExists('manga_trusted_signers')) {
              await m.createTable(mangaTrustedSigners);
            }
          }
          if (from < 66) {
            // v66（TODO-2484/2491）：
            // （原写作 v65，集成时与 develop 已落地的 Mihon 漫画扩展生态 v65
            //   撞号，顺延到 v66；两条迁移互不相干、无顺序耦合。）
            // ① 新增 collection_relations —— 合集「相关作品」边表（Bangumi
            //    subject relations / TMDB tv seasons 与 movie
            //    belongs_to_collection 的落地宿主）。纯新增表：旧库升级后本表
            //    为空 = 全部合集无相关作品数据，UI 不渲染该区块，逐像素不变；
            //    重刮一次即回填（Never break userspace）。
            // ② video_scrape_meta 加 episode_number 列 —— 集级刮削对齐后的
            //    源侧集号。纯 ADD COLUMN，列 nullable 且无 DEFAULT → 既有全部
            //    行回填 NULL = 旧的作品级资料，消费方按 NULL 走旧行为。
            // 幂等：fresh DB 已由 onCreate 的 createAll 建好，重复升级时
            // _tableExists / _columnExists 短路 no-op。
            if (!await _tableExists('collection_relations')) {
              await m.createTable(collectionRelations);
            }
            if (await _tableExists('video_scrape_meta') &&
                !await _columnExists('video_scrape_meta', 'episode_number')) {
              await m.addColumn(videoScrapeMeta, videoScrapeMeta.episodeNumber);
            }
          }
          if (from < 67) {
            // v67：reading_hourly_logs 加 format 列（写入面身份，
            // `BookFormat.dbValue`），唯一键 {dateKey,hour} → {dateKey,hour,format}。
            // 此前时段表没有任何身份列，EPUB / PDF / 漫画同一小时的时长写入时就被
            // 加成一行、永久分不开（日级 reading_statistics 靠 title→format 能拆，
            // 只有时段表拆不开）。唯一键变更须重建表，走 alterTable 按当前 Dart
            // 定义重建 + 按列名拷贝，既有行 format 落列默认 ''（= 历史未区分——
            // 信息在写入时已丢，如实标注，不猜身份）；全部旧行 format 同为 ''，
            // 新唯一键下仍互不冲突，零丢行。_columnExists 双守卫：从 v1 起的完整
            // 阶梯里本表以最新定义建出（已含此列），重复升级短路 no-op（风格同 v39）。
            if (await _tableExists('reading_hourly_logs') &&
                !await _columnExists('reading_hourly_logs', 'format')) {
              await m.alterTable(TableMigration(
                readingHourlyLogs,
                newColumns: [readingHourlyLogs.format],
              ));
            }
          }
          if (from < 68) {
            // v68（Jellyfin 图组对齐）：新增 media_images —— 媒体附加图组表
            // （backdrop 多张 / logo / title_card，归属合集或单视频二选一）。
            // 建表后一次性把 v64 的 collection_scrape_meta.backdrop_path 搬进来
            // （kind='backdrop', position=0），旧列自此冻结为遗留残留（Series
            // 先例）：读写一律走 media_images。搬运只在建表的同一分支里跑——
            // 重复升级时 _tableExists 短路，绝不重插；fresh DB 走 onCreate
            // createAll，本就没有旧数据可搬（Never break userspace：旧库升级后
            // 详情页 hero 读到的背景与升级前同一张文件，逐像素不变）。
            if (!await _tableExists('media_images')) {
              await m.createTable(mediaImages);
              if (await _tableExists('collection_scrape_meta') &&
                  await _columnExists(
                      'collection_scrape_meta', 'backdrop_path')) {
                // 搬运期间必须关 FK 强制。media_images 带两条外键
                // （collection_id -> media_collections、book_uid -> video_books），
                // 而 SQLite 是在**执行 DML 时**才去解析父表的：父表不在场就直接抛
                // `no such table: main.<父表>` 中断整条 onUpgrade（= 库打不开），
                // 且与本条 INSERT 搬几行、book_uid 是否恒为 NULL 全都无关。两张父表
                // 各自只在自己那一级阶梯里建（video_books 在 from<17 / from<20，
                // media_collections 在 from<38），没走到那一级的库到这里就是缺席。
                // 关 FK 是 v16/v57 的既有先例：搬运的引用完整性由源表
                // collection_scrape_meta 自己的外键继承，不需要在这里再验一遍；也
                // 刻意不加 foreign_key_check 门 —— 真库若存过孤儿刮削行，抛错就等于
                // 把用户锁死在「app 打不开」，代价远大于一行永不渲染的残图。
                // 收尾**恢复进入本步时的取值**，不像 v57 那样无条件置 ON：那会把
                // 调用方（含迁移测试）显式关掉的 FK 悄悄打开，改变后续步骤的行为。
                final bool foreignKeysWereOn = await _foreignKeysEnabled();
                await customStatement('PRAGMA foreign_keys = OFF');
                try {
                  await customStatement(
                    'INSERT INTO media_images '
                    '(collection_id, kind, position, path) '
                    "SELECT collection_id, 'backdrop', 0, backdrop_path "
                    'FROM collection_scrape_meta '
                    "WHERE backdrop_path IS NOT NULL AND backdrop_path != ''",
                  );
                } finally {
                  if (foreignKeysWereOn) {
                    await customStatement('PRAGMA foreign_keys = ON');
                  }
                }
              }
            }
          }
          if (from < 69) {
            // v69（Fushi 终局清算 W1）：hibiki_paired_peers → fushi_paired_peers
            // 表改名。纯 RENAME：不 DROP / 不改列 / 不删行 / 不回填行，UNIQUE
            // (peer_id) 的 sqlite_autoindex 随表自动迁移，本表无显式索引/触发器。
            // 双守卫幂等：旧名不存在（<31 阶梯已直接建新名 / fresh DB）或新名已
            // 存在（重复升级）都 no-op。旧名此后只允许活在本迁移步里。
            if (await _tableExists('hibiki_paired_peers') &&
                !await _tableExists('fushi_paired_peers')) {
              await customStatement(
                  'ALTER TABLE hibiki_paired_peers RENAME TO fushi_paired_peers');
            }
          }
        },
        onCreate: (m) async {
          await m.createAll();
          await _ensureIndexes();
        },
        beforeOpen: (details) async {
          // Second, belt-and-suspenders downgrade guard. drift calls beforeOpen
          // on every open with the on-disk version (`versionBefore`, null for a
          // freshly created DB) and the code version (`versionNow`). On a real
          // downgrade onUpgrade already threw above (hadUpgrade is true when
          // versionBefore != versionNow), but if that branch is ever weakened
          // this independent check still refuses the open before any query runs.
          // No DROP / migration here — just throw to abort the open with the DB
          // untouched.
          final int? before = details.versionBefore;
          if (before != null && before > schemaVersion) {
            throw FushiDatabaseDowngradeException(
              dbVersion: before,
              appSchemaVersion: schemaVersion,
            );
          }
        },
      );

  /// Creates all secondary indexes idempotently. Called from onCreate (fresh
  /// install) and the one-time v14 onUpgrade step — NOT on every open. Each
  /// index is guarded by a table-existence check because a partially-migrated
  /// legacy DB may lack some v1 baseline tables (those are created only in
  /// onCreate, never in the onUpgrade ladder).
  Future<void> _ensureIndexes() async {
    const List<List<String>> indexes = <List<String>>[
      [
        'profile_settings',
        'CREATE INDEX IF NOT EXISTS idx_profile_settings_profile ON profile_settings (profile_id)'
      ],
      [
        'media_type_profiles',
        'CREATE INDEX IF NOT EXISTS idx_media_type_profiles_profile ON media_type_profiles (profile_id)'
      ],
      [
        'book_profiles',
        'CREATE INDEX IF NOT EXISTS idx_book_profiles_profile ON book_profiles (profile_id)'
      ],
      [
        'bookmarks',
        'CREATE INDEX IF NOT EXISTS idx_bookmarks_book_key_created '
            'ON bookmarks (book_key, created_at DESC)'
      ],
      [
        'media_items',
        'CREATE INDEX IF NOT EXISTS idx_media_items_type '
            'ON media_items (media_type_identifier)'
      ],
      [
        'media_items',
        'CREATE INDEX IF NOT EXISTS idx_media_items_source '
            'ON media_items (media_source_identifier)'
      ],
      [
        'audio_cues',
        'CREATE INDEX IF NOT EXISTS idx_audio_cues_book_key '
            'ON audio_cues (book_key)'
      ],
      [
        'search_history_items',
        'CREATE INDEX IF NOT EXISTS idx_search_history_key '
            'ON search_history_items (history_key)'
      ],
      [
        'audiobooks',
        'CREATE INDEX IF NOT EXISTS idx_audiobooks_book_key '
            'ON audiobooks (book_key)'
      ],
      [
        'srt_books',
        'CREATE INDEX IF NOT EXISTS idx_srt_books_book_key '
            'ON srt_books (book_key)'
      ],
      [
        'book_tag_mappings',
        'CREATE INDEX IF NOT EXISTS idx_book_tag_mappings_book_key '
            'ON book_tag_mappings (book_key)'
      ],
      // BUG-906 (B): hot-path indexes that were missing.
      // audio_cues is read on every audiobook chapter load via
      // getCuesForChapter (WHERE book_key AND chapter_href ORDER BY
      // sentence_index) and findCue (WHERE book_key AND chapter_href AND
      // sentence_index). The lone single-column idx_audio_cues_book_key can't
      // serve the chapter_href filter or the sentence_index sort. A composite
      // (book_key, chapter_href, sentence_index) covers filter + sort for both,
      // and its leading book_key column still serves the book-only queries.
      [
        'audio_cues',
        'CREATE INDEX IF NOT EXISTS idx_audio_cues_book_chapter_sentence '
            'ON audio_cues (book_key, chapter_href, sentence_index)'
      ],
      // tag_id lookups: countBooksForTag on each mapping table runs
      // `WHERE tag_id IN (...) GROUP BY <owner> HAVING COUNT(DISTINCT tag_id)`.
      // The existing indexes only cover the owner-key side (book_key / etc.),
      // leaving the tag_id filter to a full scan. Add a tag_id index to every
      // mapping table.
      [
        'book_tag_mappings',
        'CREATE INDEX IF NOT EXISTS idx_book_tag_mappings_tag_id '
            'ON book_tag_mappings (tag_id)'
      ],
      [
        'srt_book_tag_mappings',
        'CREATE INDEX IF NOT EXISTS idx_srt_book_tag_mappings_tag_id '
            'ON srt_book_tag_mappings (tag_id)'
      ],
      [
        'video_book_tag_mappings',
        'CREATE INDEX IF NOT EXISTS idx_video_book_tag_mappings_tag_id '
            'ON video_book_tag_mappings (tag_id)'
      ],
      [
        'galgame_tag_mappings',
        'CREATE INDEX IF NOT EXISTS idx_galgame_tag_mappings_tag_id '
            'ON galgame_tag_mappings (tag_id)'
      ],
      [
        'galgame_tag_mappings',
        'CREATE INDEX IF NOT EXISTS idx_galgame_tag_mappings_game_id '
            'ON galgame_tag_mappings (game_id)'
      ],
      // favorite_words is filtered by source_type ('book' | 'video') in
      // getFavoritesBySource; the table had no index on it.
      [
        'favorite_words',
        'CREATE INDEX IF NOT EXISTS idx_favorite_words_source_type '
            'ON favorite_words (source_type)'
      ],
      // v49：首页 Activity 面板按 timestamp_ms DESC 取最近 N 条（可按 event_type
      // 过滤），主排序列建索引避免全表扫描 + 排序。
      [
        'activity_events',
        'CREATE INDEX IF NOT EXISTS idx_activity_events_timestamp '
            'ON activity_events (timestamp_ms DESC)'
      ],
    ];
    for (final List<String> entry in indexes) {
      if (await _tableExists(entry[0])) {
        await customStatement(entry[1]);
      }
    }
  }

  /// PRE-v16 index creation for the from<14 upgrade step. Mirrors the old
  /// (book_uid / ttu_book_id / book_id) column names that still exist before
  /// the v16 book-key migration rebuilds those tables. The v16 step recreates
  /// these under the new book_key column names via [_ensureIndexes].
  ///
  /// Each entry is `[table, sql, requiredColumn?]`. When [requiredColumn] is
  /// present it is also column-guarded: a DB that arrives at this step with its
  /// book tables already created fresh under the v16 schema (e.g. a pre-v11 DB
  /// where the from<11 ladder step ran `createTable` with the current
  /// generated `book_key` columns) does NOT have the legacy `ttu_book_id` /
  /// `book_uid` / `book_id` column, so creating the legacy-named index would
  /// throw "no such column". The v16 step recreates these under `book_key`.
  Future<void> _ensureLegacyIndexesV14() async {
    const List<List<String>> indexes = <List<String>>[
      [
        'profile_settings',
        'CREATE INDEX IF NOT EXISTS idx_profile_settings_profile ON profile_settings (profile_id)'
      ],
      [
        'media_type_profiles',
        'CREATE INDEX IF NOT EXISTS idx_media_type_profiles_profile ON media_type_profiles (profile_id)'
      ],
      [
        'book_profiles',
        'CREATE INDEX IF NOT EXISTS idx_book_profiles_profile ON book_profiles (profile_id)'
      ],
      [
        'bookmarks',
        'CREATE INDEX IF NOT EXISTS idx_bookmarks_ttu_book_id_created '
            'ON bookmarks (ttu_book_id, created_at DESC)',
        'ttu_book_id'
      ],
      [
        'media_items',
        'CREATE INDEX IF NOT EXISTS idx_media_items_type '
            'ON media_items (media_type_identifier)'
      ],
      [
        'media_items',
        'CREATE INDEX IF NOT EXISTS idx_media_items_source '
            'ON media_items (media_source_identifier)'
      ],
      [
        'audio_cues',
        'CREATE INDEX IF NOT EXISTS idx_audio_cues_book_uid '
            'ON audio_cues (book_uid)',
        'book_uid'
      ],
      [
        'search_history_items',
        'CREATE INDEX IF NOT EXISTS idx_search_history_key '
            'ON search_history_items (history_key)'
      ],
      [
        'audiobooks',
        'CREATE INDEX IF NOT EXISTS idx_audiobooks_book_uid '
            'ON audiobooks (book_uid)',
        'book_uid'
      ],
      [
        'srt_books',
        'CREATE INDEX IF NOT EXISTS idx_srt_books_ttu_book_id '
            'ON srt_books (ttu_book_id)',
        'ttu_book_id'
      ],
      [
        'book_tag_mappings',
        'CREATE INDEX IF NOT EXISTS idx_book_tag_mappings_book_id '
            'ON book_tag_mappings (book_id)',
        'book_id'
      ],
      // v55 游戏库：会话表按游戏取流水（详情页时间线）与全局按时间取最近游玩
      // （首页「最近玩过」）是两条热路径，各建一条索引。
      [
        'galgame_sessions',
        'CREATE INDEX IF NOT EXISTS idx_galgame_sessions_game_start '
            'ON galgame_sessions (game_id, start_ms DESC)',
        'game_id'
      ],
      [
        'galgame_sessions',
        'CREATE INDEX IF NOT EXISTS idx_galgame_sessions_start '
            'ON galgame_sessions (start_ms DESC)',
        'start_ms'
      ],
      // 按天聚合（统计页每日柱状图）走 dateKey。
      [
        'galgame_sessions',
        'CREATE INDEX IF NOT EXISTS idx_galgame_sessions_date '
            'ON galgame_sessions (date_key)',
        'date_key'
      ],
    ];
    for (final List<String> entry in indexes) {
      if (!await _tableExists(entry[0])) continue;
      if (entry.length > 2 && !await _columnExists(entry[0], entry[2])) {
        continue;
      }
      await customStatement(entry[1]);
    }
  }

  static final RegExp _identifierRe = RegExp(r'^[a-zA-Z_]\w*$');

  Future<bool> _columnExists(String tableName, String columnName) async {
    if (!_identifierRe.hasMatch(tableName)) {
      throw ArgumentError.value(
          tableName, 'tableName', 'not a valid identifier');
    }
    if (!_identifierRe.hasMatch(columnName)) {
      throw ArgumentError.value(
          columnName, 'columnName', 'not a valid identifier');
    }
    final rows = await customSelect('PRAGMA table_info($tableName)').get();
    return rows.any((row) => row.read<String>('name') == columnName);
  }

  /// 当前连接上 `PRAGMA foreign_keys` 的取值。迁移里要临时关外键时用它记住进入
  /// 时的状态，收尾按原值恢复 —— 无条件置 ON 会把调用方显式关掉的外键悄悄打开。
  Future<bool> _foreignKeysEnabled() async {
    final QueryRow row = await customSelect('PRAGMA foreign_keys').getSingle();
    return row.read<int>('foreign_keys') == 1;
  }

  Future<bool> _tableExists(String tableName) async {
    if (!_identifierRe.hasMatch(tableName)) {
      throw ArgumentError.value(
          tableName, 'tableName', 'not a valid identifier');
    }
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable<String>(tableName)],
    ).get();
    return rows.isNotEmpty;
  }

  /// v55 一次性回填：把偏好表 legacy key `galgame_library` 里的 6 字段 JSON 列表
  /// 搬进 [galgames] 表。
  ///
  /// 幂等：表里已有行就直接返回（重复升级 / 已回填过都短路），所以即便迁移被中断
  /// 重跑也不会产生重复条目。容错：整串解析失败、非数组、单条缺关键字段一律**跳过
  /// 该条**而不是让整个迁移炸掉——迁移中途抛异常会让 drift 停在半升级状态，
  /// 代价远大于丢一条脏数据。
  ///
  /// 解析逻辑与 app 侧 `galgame_library.dart` 的 `decodeGalgameLibrary` 同构，
  /// 但这里是独立实现：hibiki_core 是 app 的依赖，不能反向 import app 代码。
  Future<void> _backfillGalgamesFromPreferences() async {
    final int existing = await galgames.count().getSingle();
    if (existing > 0) {
      return;
    }
    // `preferences` 在极早期 schema 里可能还不存在（v1 baseline 之前的库、以及
    // 半迁移的历史库）。迁移里任何跨表读取都必须先 _tableExists——这里少了这个
    // 守卫会让整条 onUpgrade 抛 "no such table: preferences" 而中断，代价是用户库
    // 停在半升级状态。
    if (!await _tableExists('preferences')) {
      return;
    }
    final List<QueryRow> prefRows = await customSelect(
      'SELECT value FROM preferences WHERE key = ?',
      variables: [Variable<String>('galgame_library')],
    ).get();
    if (prefRows.isEmpty) {
      return;
    }
    final String raw = prefRows.first.read<String>('value');
    if (raw.isEmpty) {
      return;
    }
    late final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! List) {
      return;
    }
    for (final Object? entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      final Object? id = entry['id'];
      final Object? name = entry['name'];
      final Object? exePath = entry['exePath'];
      if (id is! String ||
          name is! String ||
          exePath is! String ||
          id.isEmpty ||
          exePath.isEmpty) {
        continue;
      }
      final Object? workdir = entry['workdir'];
      final Object? coverPath = entry['coverPath'];
      final Object? addedAt = entry['addedAt'];
      await into(galgames).insert(
        GalgamesCompanion.insert(
          id: id,
          name: name,
          exePath: exePath,
          workdir: workdir is String ? workdir : _defaultWorkdirForExe(exePath),
          coverPath: Value<String?>(
              coverPath is String && coverPath.isNotEmpty ? coverPath : null),
          addedAt: addedAt is int ? addedAt : 0,
        ),
        mode: InsertMode.insertOrIgnore,
      );
    }
  }

  /// 取 exe 所在目录作默认工作目录（兼容 `\` 与 `/` 分隔）；无分隔符时回退空串。
  /// 与 app 侧 `galgame_library.dart` 的同名私有函数同构（见上，不能反向 import）。
  static String _defaultWorkdirForExe(String exePath) {
    final int slash = exePath.lastIndexOf(RegExp(r'[\\/]'));
    return slash <= 0 ? '' : exePath.substring(0, slash);
  }

  /// Whether video_books is keyed by book_uid (the unified v20 shape) rather
  /// than the legacy autoincrement `id` PK the video worktree's v16-v19 used.
  /// Probes the actual table_info so the v20 convergence step can tell a
  /// video-line fork (id PK -> must rebuild) from an already-correct table.
  Future<bool> _videoBooksKeyedByBookUid() async {
    final rows = await customSelect("PRAGMA table_info('video_books')").get();
    final Iterable<QueryRow> pkCols =
        rows.where((QueryRow r) => r.read<int>('pk') > 0);
    return pkCols.length == 1 &&
        pkCols.first.read<String>('name') == 'book_uid';
  }

  /// TODO-809 自愈回填：把 `audiobooks` 里 `book_key` 与任一 `epub_books.book_key`
  /// 失配的旧行，经其 SRT 伴生记录的标题在 `epub_books` 中**唯一匹配**到的真实
  /// book_key，三表（audiobooks / srt_books / audio_cues）一致改写回去，让书架耳机
  /// 徽章（判据 = `audiobooks.book_key == epub_books.book_key`）重新查得中。
  ///
  /// 失配根因：BUG-414 修复前，sync/导入侧用 `sanitizeTtuFilename(title)` 重算
  /// book_key 而非 host 真实 key 写库。写入侧现已干净，但已落库失配旧行需此一次性
  /// 安全回填修复。
  ///
  /// 匹配链路：失配 audiobook -> 同 book_key 的 srt_books 行（伴生 SRT）-> 该 SRT
  /// 的 `title` -> `epub_books.title`。仅当该 title 在 epub_books 中**恰好 1 条**
  /// （`COUNT(*) == 1`）时才视为安全匹配并改写；0 条（孤儿）或 >1 条（同名歧义）
  /// 一律保持原值不动，仅记日志。
  ///
  /// 安全边界（Never break userspace）：
  /// - 只在唯一安全匹配（m == 1）时改写，绝不盲改、绝不删行。
  /// - 改写前先排除「目标真实 key 已被另一行 audiobook 占用」的情形（避免撞
  ///   `audiobooks.book_key UNIQUE` 等唯一约束），歧义同样跳过。
  /// - 全程单事务；幂等——健全库（无失配行）下自动 no-op，零行变更；可重复执行无
  ///   副作用（再次执行时所有行已匹配，候选集为空）。
  /// - 缺表（partial DB 无 audiobooks/srt_books/epub_books）守卫跳过。
  Future<void> backfillMismatchedAudiobookKeysV26() async {
    if (!await _tableExists('audiobooks') ||
        !await _tableExists('srt_books') ||
        !await _tableExists('epub_books')) {
      return;
    }
    // 列守卫：极端 partial/legacy DB 可能缺 book_key 列（理论上到 v26 已 re-key，
    // 但守卫成本低、可彻底避免 "no such column" 抛错中断整条迁移）。
    if (!await _columnExists('audiobooks', 'book_key') ||
        !await _columnExists('srt_books', 'book_key') ||
        !await _columnExists('srt_books', 'title') ||
        !await _columnExists('epub_books', 'book_key') ||
        !await _columnExists('epub_books', 'title')) {
      return;
    }
    final bool hasAudioCues = await _tableExists('audio_cues') &&
        await _columnExists('audio_cues', 'book_key');

    await transaction(() async {
      // 候选：audiobooks.book_key 不在 epub_books 任何 book_key 里（失配），且其
      // 同 book_key 的 srt_books.title 在 epub_books 中唯一匹配（COUNT == 1）。
      // newKey = 该唯一 epub_books.book_key。
      final List<QueryRow> candidates = await customSelect(
        'SELECT a.book_key AS old_key, '
        '(SELECT e.book_key FROM epub_books e WHERE e.title = s.title) AS new_key '
        'FROM audiobooks a '
        'JOIN srt_books s ON s.book_key = a.book_key '
        'WHERE a.book_key NOT IN (SELECT book_key FROM epub_books) '
        'AND (SELECT COUNT(*) FROM epub_books e WHERE e.title = s.title) = 1',
      ).get();

      int rewritten = 0;
      int skippedTargetOccupied = 0;
      int skippedAmbiguousOldKey = 0;
      final Set<String> claimedNewKeys = <String>{};

      // 同一 old_key 经多条 SRT 解析到不同 new_key 的歧义行剔除（srt_books 对
      // book_key 不设唯一约束，防御性处理）。
      final Map<String, Set<String>> oldToNew = <String, Set<String>>{};
      for (final QueryRow row in candidates) {
        final String oldKey = row.read<String>('old_key');
        final String newKey = row.read<String>('new_key');
        (oldToNew[oldKey] ??= <String>{}).add(newKey);
      }

      for (final MapEntry<String, Set<String>> entry in oldToNew.entries) {
        final String oldKey = entry.key;
        if (entry.value.length != 1) {
          skippedAmbiguousOldKey += 1;
          continue;
        }
        final String newKey = entry.value.first;
        // 目标真实 key 已被另一行 audiobook（或本批已认领）占用 -> 跳过，避免撞
        // audiobooks.book_key UNIQUE。
        final List<QueryRow> occupied = await customSelect(
          'SELECT 1 FROM audiobooks WHERE book_key = ? LIMIT 1',
          variables: <Variable>[Variable<String>(newKey)],
        ).get();
        if (occupied.isNotEmpty || claimedNewKeys.contains(newKey)) {
          skippedTargetOccupied += 1;
          continue;
        }
        claimedNewKeys.add(newKey);

        await customStatement(
          'UPDATE audiobooks SET book_key = ? WHERE book_key = ?',
          <Object?>[newKey, oldKey],
        );
        await customStatement(
          'UPDATE srt_books SET book_key = ? WHERE book_key = ?',
          <Object?>[newKey, oldKey],
        );
        if (hasAudioCues) {
          await customStatement(
            'UPDATE audio_cues SET book_key = ? WHERE book_key = ?',
            <Object?>[newKey, oldKey],
          );
        }
        rewritten += 1;
      }

      debugPrint(
        '[fushi-migration v26] audiobook book_key backfill: '
        'rewritten=$rewritten, '
        'skippedAmbiguousOldKey=$skippedAmbiguousOldKey, '
        'skippedTargetOccupied=$skippedTargetOccupied '
        '(orphans/同名歧义的失配行保持原值不动)',
      );
    });
  }

  /// TODO-894：为缺失配对 srt_books 行的 EPUB-backed 有声书补写一条 srt_books
  /// 行（v29 自愈迁移），仿 [backfillMismatchedAudiobookKeysV26] 范式：表/列守卫 →
  /// transaction → 裸 SQL → debugPrint 计数。
  ///
  /// 候选只取「audiobooks.book_key 能 JOIN 上 epub_books（即 EPUB-backed），且其
  /// book_key 不在任何 srt_books.book_key 里」。standalone 纯字幕书（有 srt_books
  /// 但**无 audiobooks 行**）天然不进 `FROM audiobooks a`，永不误伤。
  ///
  /// uid 与导入路径共用稳定派生 `srtbook_epub_<book_key>`；`INSERT OR IGNORE` +
  /// `WHERE NOT IN` 双重幂等（重复跑迁移不新增行、不改既有行）。cover_path 留空
  /// （export 不依赖 srtBook.coverPath）。
  Future<void> backfillMissingAudiobookSrtBooksV29() async {
    if (!await _tableExists('audiobooks') ||
        !await _tableExists('srt_books') ||
        !await _tableExists('epub_books')) {
      return;
    }
    if (!await _columnExists('audiobooks', 'book_key') ||
        !await _columnExists('audiobooks', 'alignment_path') ||
        !await _columnExists('audiobooks', 'audio_paths_json') ||
        !await _columnExists('srt_books', 'uid') ||
        !await _columnExists('srt_books', 'book_key') ||
        !await _columnExists('srt_books', 'srt_path') ||
        !await _columnExists('srt_books', 'title') ||
        !await _columnExists('epub_books', 'book_key') ||
        !await _columnExists('epub_books', 'title') ||
        !await _columnExists('epub_books', 'imported_at')) {
      return;
    }

    await transaction(() async {
      final List<QueryRow> candidates = await customSelect(
        'SELECT a.book_key AS book_key, '
        'a.alignment_path AS srt_path, '
        'a.audio_paths_json AS audio_json, '
        'e.title AS title, e.author AS author, e.imported_at AS imported '
        'FROM audiobooks a '
        'JOIN epub_books e ON e.book_key = a.book_key '
        'WHERE a.book_key NOT IN (SELECT book_key FROM srt_books)',
      ).get();

      int inserted = 0;
      for (final QueryRow row in candidates) {
        final String bookKey = row.read<String>('book_key');
        await customStatement(
          'INSERT OR IGNORE INTO srt_books '
          '(uid, title, author, audio_paths_json, srt_path, cover_path, '
          'imported_at, book_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'srtbook_epub_$bookKey',
            row.read<String>('title'),
            row.read<String?>('author'),
            row.read<String?>('audio_json'),
            row.read<String>('srt_path'),
            null, // cover_path: export 不依赖
            row.read<int>('imported'),
            bookKey,
          ],
        );
        inserted += 1;
      }

      debugPrint(
        '[fushi-migration v29] EPUB-backed audiobook srt_books backfill: '
        'inserted=$inserted '
        '(standalone 字幕书无 audiobooks 行天然豁免，重复迁移幂等)',
      );
    });
  }

  /// v38 迁移：把旧 [Series] + [ShelfEntries].seriesId 归属转成 [MediaCollections]
  /// (type='collection') + [MediaCollectionItems]。成员按旧 sort_order 转 sort_index；
  /// 转完把 shelf_entries.series_id 全清 NULL（seriesId 语义作废，sortOrder 书架排序
  /// 职责保留）并删 series 行（转换完成，避免留 0 成员孤儿系列 + getAllSeries 空）。
  /// 由 onUpgrade 的 from<38 门槛保证单次执行。
  Future<void> migrateSeriesToCollectionsV38() async {
    if (!await _tableExists('series') || !await _tableExists('shelf_entries')) {
      return;
    }
    await transaction(() async {
      final List<QueryRow> seriesRows = await customSelect(
        'SELECT id, name, sort_order, created_at FROM series ORDER BY id',
      ).get();
      int convertedCollections = 0;
      for (final QueryRow s in seriesRows) {
        final int seriesId = s.read<int>('id');
        final List<QueryRow> members = await customSelect(
          'SELECT media_type, entry_key FROM shelf_entries '
          'WHERE series_id = ? ORDER BY sort_order, entry_key',
          variables: [Variable.withInt(seriesId)],
        ).get();
        // 0 成员系列不建空合集（例如其唯一成员是先跑的拆集删掉的 playlist parent）。
        if (members.isEmpty) continue;
        final int collectionId = await customInsert(
          'INSERT INTO media_collections '
          '(name, collection_type, cover_source, sort_order, created_at) '
          "VALUES (?, 'collection', NULL, ?, ?)",
          variables: [
            Variable.withString(s.read<String>('name')),
            Variable.withInt(s.read<int>('sort_order')),
            Variable.withInt(s.read<int>('created_at')),
          ],
        );
        int idx = 0;
        for (final QueryRow member in members) {
          await customStatement(
            'INSERT OR IGNORE INTO media_collection_items '
            '(collection_id, media_type, entry_key, sort_index) '
            'VALUES (?, ?, ?, ?)',
            <Object?>[
              collectionId,
              member.read<String>('media_type'),
              member.read<String>('entry_key'),
              idx,
            ],
          );
          idx += 1;
        }
        convertedCollections += 1;
      }
      // seriesId 语义作废（sortOrder 保留）+ 删已转换的 series 行。先 UPDATE 断开外键
      // 引用再 DELETE（等效 FK onDelete:setNull，但显式）。
      await customStatement('UPDATE shelf_entries SET series_id = NULL');
      await customStatement('DELETE FROM series');
      debugPrint(
        '[fushi-migration v38] series→collection converted='
        '$convertedCollections',
      );
    });
  }

  /// v38 迁移：把每条多集 playlist video_books 行拆成 N 条独立集行 + 一个 playlist
  /// [MediaCollections]，并改写 mined_sentences / favorite_sentences 的集坐标，使拆集
  /// 后旧收藏/制卡跳转仍指向正确的集（Never break userspace）。单视频行（playlist_json
  /// 为 null / 空 / <2 集 / 坏 JSON）原样不动。由 from<38 门槛保证单次执行。
  Future<void> splitPlaylistVideoBooksV38() async {
    if (!await _tableExists('video_books')) return;
    // playlist_json 是拆集触发列，也是后续 SELECT * 各列读取的前提。它随 video_books
    // 建表而生（非后期 addColumn），故任何经真实 ladder 升到 v38 的库都有它；仅极简
    // 测试种子可能缺列 → 无 playlist 可拆，直接跳过（防 SELECT * 读缺列崩溃）。
    if (!await _columnExists('video_books', 'playlist_json')) return;
    final bool hasMined = await _tableExists('mined_sentences');
    final bool hasTags = await _tableExists('video_book_tag_mappings');
    final bool hasShelf = await _tableExists('shelf_entries');
    final bool hasPrefs = await _tableExists('preferences');
    // v57 把 video_book_tag_mappings.video_book_uid 更名 book_uid。真实旧库跑到
    // 本步（v38 < v57）时列仍叫 video_book_uid；但 mid-ladder 由 m.createTable
    // 按当前 Dart 定义 fresh 建出的表已是 book_uid（先例：v10/v11 的列名守卫）。
    // 按实际列名写 SQL，两种 shape 都不崩。
    final String tagUidCol = hasTags &&
            await _columnExists('video_book_tag_mappings', 'video_book_uid')
        ? 'video_book_uid'
        : 'book_uid';

    // parentUid → 拆出的集 uid 列表 / 恢复集下标：供循环外一次性改写 favorite_sentences
    // pref（单一 JSON blob，含全部来源收藏句）。
    final Map<String, List<String>> splitMap = <String, List<String>>{};
    final Map<String, int> currentEpisodeMap = <String, int>{};

    await transaction(() async {
      // 现存全部 book_uid（含单视频），用于拆出集 uid 去重。
      final Set<String> taken = <String>{
        for (final QueryRow r
            in await customSelect('SELECT book_uid FROM video_books').get())
          r.read<String>('book_uid'),
      };

      final List<QueryRow> playlistRows = await customSelect(
        'SELECT * FROM video_books '
        "WHERE playlist_json IS NOT NULL AND playlist_json != ''",
      ).get();

      int splitCount = 0;
      for (final QueryRow row in playlistRows) {
        final String parentUid = row.read<String>('book_uid');
        final String rawJson = row.read<String>('playlist_json');
        List<dynamic> entries;
        try {
          final dynamic decoded = jsonDecode(rawJson);
          if (decoded is! List) continue;
          entries = decoded;
        } catch (_) {
          continue; // 坏 JSON：保守跳过，保留原行（Never break userspace）。
        }
        if (entries.length < 2) continue; // 单集/空：不是播放列表，原样保留。

        final String parentTitle = row.read<String>('title');
        final int baseImportedAt = row.read<int?>('imported_at') ?? 0;
        final int currentEpisode = (row.read<int?>('current_episode') ?? 0)
            .clamp(0, entries.length - 1);
        // 整本共享列（字幕/音轨/延迟/来源等各集照抄——原本各集就共用一列）。
        final String? subtitleSource = row.read<String?>('subtitle_source');
        final String? secondarySub =
            row.read<String?>('secondary_subtitle_source');
        final String? subtitleFormat = row.read<String?>('subtitle_format');
        final int? embeddedTrack = row.read<int?>('embedded_subtitle_track');
        final String? audioTrackId = row.read<String?>('audio_track_id');
        final int delayMs = row.read<int?>('delay_ms') ?? 0;
        final int? sourceId = row.read<int?>('source_id');
        final String? streamSpec = row.read<String?>('stream_spec_json');
        // 非共享列，逐集差异化承接：
        // - last_position_ms：旧版 playlist（无 per-episode positionMs）当前集续播点只
        //   存在于 parent.last_position_ms，给 currentEpisode 兜底，避免删父行后丢失。
        // - cover_path：整本一张封面（手动/自动），只让第 0 集承接（合集自动封面取首
        //   成员），避免静默丢失。
        // - completed_at：**不照抄**——v37 的 completedAt 是「至少看完过其中一集」的整本
        //   标记，无脑复制给 N 集会把未看的集标成完成 + 完成统计 N 倍膨胀。各集重新播到
        //   90% 再各自标记（宁可少计一次，不误标完成）。
        final int parentLastPos = row.read<int?>('last_position_ms') ?? 0;
        final String? parentCover = row.read<String?>('cover_path');

        final List<String> epUids = <String>[];
        for (int i = 0; i < entries.length; i++) {
          final dynamic e = entries[i];
          final Map<String, dynamic> entry =
              e is Map<String, dynamic> ? e : <String, dynamic>{};
          // 软转 + 缺省兜底：legacy / 外部导入的 playlist_json 若某字段类型异常（path 存
          // 成数字等），不能用无守卫强转（会抛 → 回滚整次 v38 升级 → 每次开库重试再失败
          // → app 永久打不开）。宁可用兜底值跳过坏字段，不炸掉迁移。
          final String path =
              entry['path'] is String ? entry['path'] as String : '';
          final int positionMs = entry['positionMs'] is num
              ? (entry['positionMs'] as num).toInt()
              : 0;
          final String epTitle = entry['title'] is String
              ? entry['title'] as String
              : '$parentTitle #${i + 1}';
          // currentEpisode 且本集自身无 positionMs（旧版 playlist）→ 用 parent 续播点兜底。
          final int epLastPos = (i == currentEpisode && positionMs <= 0)
              ? parentLastPos
              : positionMs;
          final String? epCover = i == 0 ? parentCover : null;
          final String uid =
              coreUniqueVideoBookUid(coreSingleVideoBookUid(path), taken);
          taken.add(uid);
          epUids.add(uid);

          await customStatement(
            'INSERT OR IGNORE INTO video_books '
            '(book_uid, title, video_path, subtitle_source, '
            'secondary_subtitle_source, subtitle_format, '
            'embedded_subtitle_track, cover_path, last_position_ms, '
            'imported_at, playlist_json, current_episode, audio_track_id, '
            'delay_ms, completed_at, source_id, stream_spec_json) '
            // completed_at 恒 NULL（见上：不照抄 parent 整本完成标记）。
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, ?, ?, NULL, ?, ?)',
            <Object?>[
              uid,
              epTitle,
              path,
              subtitleSource,
              secondarySub,
              subtitleFormat,
              embeddedTrack,
              epCover,
              epLastPos,
              baseImportedAt + i,
              audioTrackId,
              delayMs,
              sourceId,
              streamSpec,
            ],
          );
        }

        splitMap[parentUid] = epUids;
        currentEpisodeMap[parentUid] = currentEpisode;

        // playlist 合集：name=parent.title，sort_order 取 parent 的 shelf_entries
        // sortOrder（无则 0）。created_at 契约是**毫秒**戳（同 createMediaCollection /
        // series→collection），而本步（v38 < v57）跑在 v57 之前，旧库的
        // video_books.imported_at 此刻仍是 drift DateTime（Unix **秒**存储；v57 才
        // 统一成 int 毫秒），故 ×1000 转毫秒，避免 playlist 合集 created_at 比其它
        // 合集小约 1000×（否则一旦按加入时间排序会全排到 1970）。
        int parentSort = 0;
        if (hasShelf) {
          final QueryRow? se = await customSelect(
            'SELECT sort_order FROM shelf_entries '
            "WHERE media_type = 'video' AND entry_key = ?",
            variables: [Variable.withString(parentUid)],
          ).getSingleOrNull();
          parentSort = se?.read<int>('sort_order') ?? 0;
        }
        final int collectionId = await customInsert(
          'INSERT INTO media_collections '
          '(name, collection_type, cover_source, sort_order, created_at) '
          "VALUES (?, 'playlist', NULL, ?, ?)",
          variables: [
            Variable.withString(parentTitle),
            Variable.withInt(parentSort),
            Variable.withInt(baseImportedAt * 1000),
          ],
        );
        for (int i = 0; i < epUids.length; i++) {
          await customStatement(
            'INSERT OR IGNORE INTO media_collection_items '
            '(collection_id, media_type, entry_key, sort_index) '
            "VALUES (?, 'video', ?, ?)",
            <Object?>[collectionId, epUids[i], i],
          );
        }

        // 标签：parent 的每条标签映射复制到全部集行（唯一约束冲突忽略）。
        if (hasTags) {
          final List<QueryRow> tagRows = await customSelect(
            'SELECT tag_id FROM video_book_tag_mappings '
            'WHERE $tagUidCol = ?',
            variables: [Variable.withString(parentUid)],
          ).get();
          for (final String uid in epUids) {
            for (final QueryRow t in tagRows) {
              await customStatement(
                'INSERT OR IGNORE INTO video_book_tag_mappings '
                '($tagUidCol, tag_id) VALUES (?, ?)',
                <Object?>[uid, t.read<int>('tag_id')],
              );
            }
          }
        }

        // 制卡 mined_sentences 集坐标改写：section_index=i → book_key=epUids[i],
        // section_index=0；NULL section → 归当前集；剩余越界 section → 归末集。三步按
        // book_key 过滤天然互斥（改写后 book_key 已非 parentUid，后续步不再命中）。
        if (hasMined) {
          for (int i = 0; i < epUids.length; i++) {
            await customStatement(
              'UPDATE mined_sentences SET book_key = ?, section_index = 0 '
              'WHERE book_key = ? AND section_index = ?',
              <Object?>[epUids[i], parentUid, i],
            );
          }
          await customStatement(
            'UPDATE mined_sentences SET book_key = ?, section_index = 0 '
            'WHERE book_key = ? AND section_index IS NULL',
            <Object?>[epUids[currentEpisode], parentUid],
          );
          await customStatement(
            'UPDATE mined_sentences SET book_key = ?, section_index = 0 '
            'WHERE book_key = ?',
            <Object?>[epUids[epUids.length - 1], parentUid],
          );
        }

        // 删 parent 的 video_book_tag_mappings（显式删，不依赖 FK cascade——迁移在
        // 事务内跑，FK 状态不该被假设；集行的映射引用集 uid，不受影响）+ 删 parent 行
        // + 删 parent 的 shelf_entry。
        if (hasTags) {
          await customStatement(
            'DELETE FROM video_book_tag_mappings WHERE $tagUidCol = ?',
            <Object?>[parentUid],
          );
        }
        await customStatement(
          'DELETE FROM video_books WHERE book_uid = ?',
          <Object?>[parentUid],
        );
        if (hasShelf) {
          await customStatement(
            'DELETE FROM shelf_entries '
            "WHERE media_type = 'video' AND entry_key = ?",
            <Object?>[parentUid],
          );
        }
        splitCount += 1;
      }
      debugPrint('[fushi-migration v38] playlist videos split=$splitCount');

      // favorite_sentences（收藏句）改写并入**同一事务**：整个 v38 拆集要么全成要么全
      // 回滚。否则若拆集事务先提交、收藏改写在两步之间崩溃，重跑时 parent 已删 → splitMap
      // 空 → 收藏改写被永久跳过 → 视频收藏 bookKey 悬空到已删父 uid 不可自愈。
      if (hasPrefs && splitMap.isNotEmpty) {
        await _rewriteFavoriteSentencesForSplitV38(splitMap, currentEpisodeMap);
      }
    });
  }

  /// v38：改写 preferences 里 favorite_sentences JSON blob 中、属于被拆多集视频的收藏句：
  /// bookKey → epUids[sectionIndex], sectionIndex → 0。pref 结构见
  /// FavoriteSentenceRepository（JSON 数组，每元素含 bookKey/sectionIndex/source）。
  /// 缺 pref / 空 / 坏 JSON / 无命中 → no-op（不写）。
  ///
  /// 判定只看 `splitMap[bookKey] != null`，**不看 source 字段**：splitMap 的键只可能是
  /// video 命名空间的父 uid（core*VideoBookUid 均以 'video/' 前缀），书/srt/有声书/歌词
  /// 收藏的 bookKey 是标题派生、不会撞进该命名空间，故按 bookKey 命中已唯一判定「被拆
  /// 视频父」。若额外要求 source=='video'，会漏改 source 字段缺失的旧格式视频收藏 →
  /// 拆集删父后 bookKey 永久悬空（假阴性，违反 Never break userspace）。
  Future<void> _rewriteFavoriteSentencesForSplitV38(
    Map<String, List<String>> splitMap,
    Map<String, int> currentEpisodeMap,
  ) async {
    final QueryRow? row = await customSelect(
      "SELECT value FROM preferences WHERE key = 'favorite_sentences'",
    ).getSingleOrNull();
    final String? raw = row?.read<String?>('value');
    if (raw == null || raw.isEmpty) return;
    List<dynamic> list;
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return;
      list = decoded;
    } catch (_) {
      return;
    }
    bool changed = false;
    for (final dynamic item in list) {
      if (item is! Map) continue;
      final Object? bk = item['bookKey'];
      if (bk is! String) continue;
      final List<String>? epUids = splitMap[bk];
      if (epUids == null) continue;
      final Object? rawSectionRaw = item['sectionIndex'];
      final int rawSection = rawSectionRaw is num
          ? rawSectionRaw.toInt()
          : (currentEpisodeMap[bk] ?? 0);
      final int section = rawSection.clamp(0, epUids.length - 1);
      item['bookKey'] = epUids[section];
      item['sectionIndex'] = 0;
      changed = true;
    }
    if (!changed) return;
    await customStatement(
      "UPDATE preferences SET value = ? WHERE key = 'favorite_sentences'",
      <Object?>[jsonEncode(list)],
    );
  }

  // ── preferences helpers ─────────────────────────────────────────
  Future<String?> getPref(String key) async {
    final q = select(preferences)..where((t) => t.key.equals(key));
    final row = await q.getSingleOrNull();
    return row?.value;
  }

  /// TODO-855: persisted monotonic counter, bumped on every preference write
  /// at this single lowest-level write choke point ([setPref]). It is the
  /// cross-process change signal the separate :popup process reads (via a cheap
  /// indexed row lookup) to decide whether to reload its warm-reuse pref cache,
  /// instead of unconditionally re-scanning the whole preferences table on each
  /// lookup. Sinking the bump here means EVERY path that writes a preference —
  /// PreferencesRepository, ThemeNotifier (theme / app_ui_scale), MediaSource
  /// (per-source font sizes etc.), profile switch, sync/backup restore —
  /// automatically advances it; no caller can forget to bump.
  static const String prefsVersionKey = 'prefs_version';

  Future<void> setPref(String key, String value) async {
    // BUG-906 (A): the business write and the version bump MUST land in one
    // transaction. Previously these were two independent awaits, so two
    // concurrent setPref calls could interleave between the insert and the
    // read-modify-write bump inside [_bumpPrefsVersion], losing an increment
    // (both read version=N, both write N+1) → :popup keeps serving a stale
    // pref cache. drift serializes transactions on the single write connection,
    // so wrapping insert+bump makes the whole write atomic w.r.t. any other
    // transactional pref write: no lost increments, and a cross-process reader
    // never observes the new value paired with a stale version.
    await transaction(() async {
      await into(preferences).insertOnConflictUpdate(
        PreferencesCompanion.insert(key: key, value: value),
      );
      // Bump the cross-process change signal for every real pref write. Skip
      // the version key itself (a direct write of it — e.g. a sync/backup
      // restore replaying the persisted counter — must NOT recursively bump on
      // top of its own value, which would double-count and break monotonic
      // alignment).
      if (key != prefsVersionKey) {
        await _bumpPrefsVersion();
      }
    });
  }

  /// Writes several preferences as ONE transaction with a SINGLE version bump.
  ///
  /// A multi-key preference (a tri-state projected onto two bool keys, a paired
  /// value+discriminator) is one logical setting: writing it through repeated
  /// [setPref] calls costs one transaction — and one fsync — per key, and
  /// leaves an observable window in which a cross-process reader sees half the
  /// setting applied (BUG-906 guarantees each key's own atomicity, not the
  /// group's). Measured on Windows/WAL: two [setPref] calls median 12.3ms vs
  /// 5.1ms for one, and the caller's UI update sits behind that whole wait.
  ///
  /// Same BUG-906 (A) invariant as [setPref]: the business writes and the bump
  /// land together, so no reader ever pairs a new value with a stale version.
  /// The bump happens once for the whole group (it is a change *signal*, not a
  /// per-key counter) and is skipped when the group only carries the version
  /// key itself. An empty map is a no-op — no transaction, no bump.
  Future<void> setPrefs(Map<String, String> entries) async {
    if (entries.isEmpty) return;
    await transaction(() async {
      for (final MapEntry<String, String> entry in entries.entries) {
        await into(preferences).insertOnConflictUpdate(
          PreferencesCompanion.insert(key: entry.key, value: entry.value),
        );
      }
      if (entries.keys.any((String key) => key != prefsVersionKey)) {
        await _bumpPrefsVersion();
      }
    });
  }

  /// Atomically replaces one preference only while its raw persisted value is
  /// still [expectedValue]. A successful non-version write advances
  /// [prefsVersionKey] in the same transaction; a failed comparison changes
  /// neither row.
  ///
  /// This is the DB-level primitive for migrations that start from a cached
  /// preference snapshot. An unconditional [setPref] would let an old process
  /// overwrite a newer cross-process choice after its snapshot went stale.
  Future<bool> compareAndSetPref(
    String key, {
    required String expectedValue,
    required String newValue,
  }) async {
    return transaction(() async {
      final int updated = await (update(preferences)
            ..where(
              (t) => t.key.equals(key) & t.value.equals(expectedValue),
            ))
          .write(
        PreferencesCompanion(value: Value<String>(newValue)),
      );
      if (updated != 1) return false;
      if (key != prefsVersionKey) {
        await _bumpPrefsVersion();
      }
      return true;
    });
  }

  /// Atomically increment the persisted prefs-version directly in the DB so the
  /// next cross-process read observes a strictly larger value. Encoded as a
  /// PrefCodec int (`i:N`) so it round-trips identically to every other int
  /// preference. Writes via the raw [into]/[insertOnConflictUpdate] path (NOT
  /// [setPref]) to avoid re-entering the recursion guard above.
  ///
  /// BUG-906 (A): this read-modify-write is NOT atomic on its own. It MUST be
  /// called from within an enclosing transaction — which its only two callers
  /// ([setPref] and [compareAndSetPref]) now both provide — so that drift's
  /// single-writer transaction lock serializes the read+write against every
  /// other pref write. Called bare (outside a transaction) it can lose
  /// increments under concurrency; do not add such a caller.
  Future<void> _bumpPrefsVersion() async {
    final String? raw = await getPref(prefsVersionKey);
    final int current = raw == null ? 0 : PrefCodec.decode<int>(raw, 0);
    await into(preferences).insertOnConflictUpdate(
      PreferencesCompanion.insert(
        key: prefsVersionKey,
        value: PrefCodec.encode(current + 1),
      ),
    );
  }

  Future<T> getPrefTyped<T>(String key, T defaultValue) async {
    final raw = await getPref(key);
    if (raw == null) return defaultValue;
    return PrefCodec.decode<T>(raw, defaultValue);
  }

  Future<void> setPrefTyped<T>(String key, T value) =>
      setPref(key, PrefCodec.encode(value));

  Future<void> deletePref(String key) async {
    await (delete(preferences)..where((t) => t.key.equals(key))).go();
  }

  Future<Map<String, String>> getAllPrefs() async {
    final rows = await select(preferences).get();
    return Map.fromEntries(rows.map((r) => MapEntry(r.key, r.value)));
  }

  Future<void> migrateLegacyBookmarkPreferences() async {
    if (!await _tableExists('preferences')) {
      return;
    }
    if (!await _tableExists('bookmarks')) {
      return;
    }
    // Legacy `bookmarks_<int>` prefs predate the v16 book-key migration and key
    // on the int ttu_book_id column. After v16 that column is gone (renamed to
    // book_key) and the v16 prefs migration already drained/re-keyed these, so
    // this drainer is a no-op on the post-v16 schema. Guard on the column so it
    // only runs against the pre-v16 schema it understands.
    if (!await _columnExists('bookmarks', 'ttu_book_id')) {
      return;
    }
    final Map<String, String> allPrefs = await getAllPrefs();
    await transaction(() async {
      for (final MapEntry<String, String> entry in allPrefs.entries) {
        if (!entry.key.startsWith('bookmarks_')) continue;
        final int? ttuBookId =
            int.tryParse(entry.key.substring('bookmarks_'.length));
        if (ttuBookId == null || entry.value.isEmpty) continue;
        final QueryRow countRow = await customSelect(
          'SELECT COUNT(*) AS c FROM bookmarks WHERE ttu_book_id = ?',
          variables: [Variable<int>(ttuBookId)],
        ).getSingle();
        final int existing = countRow.read<int>('c');
        if (existing == 0) {
          List<dynamic> list;
          try {
            list = jsonDecode(entry.value) as List<dynamic>;
          } catch (_) {
            await customStatement(
              'DELETE FROM preferences WHERE key = ?',
              [entry.key],
            );
            continue;
          }
          for (final dynamic raw in list) {
            if (raw is! Map<String, dynamic>) continue;
            final int sectionIndex = raw['sectionIndex'] as int? ?? 0;
            final int normCharOffset = raw['normCharOffset'] as int? ?? 0;
            final String label = raw['label'] as String? ?? '';
            final DateTime createdAt = DateTime.tryParse(
                  raw['createdAt'] as String? ?? '',
                ) ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
            final int rowBookId = raw['ttuBookId'] as int? ?? ttuBookId;
            // bookmarks.ttu_book_id is a FK to epub_books(id). Legacy TTU ids
            // need not map to an imported epub, and INSERT OR IGNORE does NOT
            // suppress FK violations — an unmatched id would abort the whole
            // upgrade transaction (app can't open the DB). Skip orphans.
            final bookExists = await customSelect(
              'SELECT 1 FROM epub_books WHERE id = ? LIMIT 1',
              variables: [Variable<int>(rowBookId)],
            ).getSingleOrNull();
            if (bookExists == null) continue;
            await customStatement(
              'INSERT OR IGNORE INTO bookmarks '
              '(ttu_book_id, section_index, norm_char_offset, label, '
              'created_at, book_title, page_in_chapter, total_pages_in_chapter) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
              [
                rowBookId,
                sectionIndex,
                normCharOffset,
                label,
                createdAt.millisecondsSinceEpoch,
                raw['bookTitle'] as String?,
                raw['pageInChapter'] as int?,
                raw['totalPagesInChapter'] as int?,
              ],
            );
          }
        }
        await customStatement(
          'DELETE FROM preferences WHERE key = ?',
          [entry.key],
        );
      }
    });
  }

  // ── media items ─────────────────────────────────────────────────
  Future<List<MediaItemRow>> getAllMediaItems() =>
      (select(mediaItems)..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  Future<void> upsertMediaItem(MediaItemsCompanion item) =>
      into(mediaItems).insertOnConflictUpdate(item);

  Future<int> deleteMediaItemByUniqueKey(String uk) =>
      (delete(mediaItems)..where((t) => t.uniqueKey.equals(uk))).go();

  Future<int> deleteMediaItemById(int id) =>
      (delete(mediaItems)..where((t) => t.id.equals(id))).go();

  Future<int> deleteMediaItemsByIdentifier(String ident) =>
      (delete(mediaItems)..where((t) => t.mediaIdentifier.equals(ident))).go();

  Future<MediaItemRow?> getMediaItemByUniqueKey(String uk) =>
      (select(mediaItems)..where((t) => t.uniqueKey.equals(uk)))
          .getSingleOrNull();

  Future<void> trimMediaHistory(String typeId, int maxItems) async {
    await transaction(() async {
      final cnt = countAll();
      final q = selectOnly(mediaItems)
        ..where(mediaItems.mediaTypeIdentifier.equals(typeId))
        ..addColumns([cnt]);
      final row = await q.getSingle();
      final count = row.read(cnt)!;
      if (count <= maxItems) return;
      final surplus = count - maxItems;
      final oldestIds = await (select(mediaItems)
            ..where((t) => t.mediaTypeIdentifier.equals(typeId))
            ..orderBy([(t) => OrderingTerm.asc(t.id)])
            ..limit(surplus))
          .map((r) => r.id)
          .get();
      await (delete(mediaItems)..where((t) => t.id.isIn(oldestIds))).go();
    });
  }

  // ── search history ──────────────────────────────────────────────
  Future<List<SearchHistoryItemRow>> getAllSearchHistoryItems() =>
      select(searchHistoryItems).get();

  Future<void> upsertSearchHistoryItem(SearchHistoryItemsCompanion item) async {
    await into(searchHistoryItems).insert(
      item,
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<int> deleteSearchHistoryByUniqueKey(String uk) =>
      (delete(searchHistoryItems)..where((t) => t.uniqueKey.equals(uk))).go();

  Future<int> clearSearchHistory(String historyKey) =>
      (delete(searchHistoryItems)
            ..where((t) => t.historyKey.equals(historyKey)))
          .go();

  Future<List<SearchHistoryItemRow>> getSearchHistory(String historyKey) =>
      (select(searchHistoryItems)
            ..where((t) => t.historyKey.equals(historyKey)))
          .get();

  Future<int> countSearchHistory(String historyKey) async {
    final cnt = countAll();
    final q = selectOnly(searchHistoryItems)
      ..where(searchHistoryItems.historyKey.equals(historyKey))
      ..addColumns([cnt]);
    final row = await q.getSingle();
    return row.read(cnt)!;
  }

  Future<void> trimSearchHistory(String historyKey, int maxItems) async {
    await transaction(() async {
      final count = await countSearchHistory(historyKey);
      if (count <= maxItems) return;
      final surplus = count - maxItems;
      final oldestIds = await (select(searchHistoryItems)
            ..where((t) => t.historyKey.equals(historyKey))
            ..orderBy([(t) => OrderingTerm.asc(t.id)])
            ..limit(surplus))
          .map((r) => r.id)
          .get();
      await (delete(searchHistoryItems)..where((t) => t.id.isIn(oldestIds)))
          .go();
    });
  }

  // ── audiobooks ──────────────────────────────────────────────────
  Future<AudiobookRow?> getAudiobookByBookKey(String bookKey) =>
      (select(audiobooks)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  Future<List<AudiobookRow>> getAllAudiobooks() => select(audiobooks).get();

  Future<void> upsertAudiobook(AudiobooksCompanion ab) =>
      into(audiobooks).insert(ab,
          onConflict: DoUpdate((_) => ab, target: [audiobooks.bookKey]));

  Future<int> deleteAudiobookByBookKey(String bookKey) => transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookKey))).go();
        // TODO-616：纯有声书 shelf_entry 以 mediaType='srt'、entryKey=bookKey 登记
        // （deleteAudiobookByBookKey 拿不到 srtUid——srtUid 级联在上层 host
        // deleteAudiobook；故登记键 = 删除键 = bookKey）。幂等（删 0 行不报错）。
        await deleteShelfEntry(MediaKind.srt, bookKey);
        return (delete(audiobooks)..where((t) => t.bookKey.equals(bookKey)))
            .go();
      });

  // ── video_books ─────────────────────────────────────────────────
  Future<void> upsertVideoBook(VideoBooksCompanion vb) async {
    await into(videoBooks).insert(vb,
        onConflict: DoUpdate((_) => vb, target: [videoBooks.bookUid]));
    // 删除传播：重新加入同 bookUid 的视频清除其 sync 删除墓碑（防误判待删）。
    if (vb.bookUid.present) {
      await clearSyncDeletionTombstone('video', vb.bookUid.value);
    }
  }

  Future<VideoBookRow?> getVideoBookByBookUid(String bookUid) =>
      (select(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  Future<List<VideoBookRow>> allVideoBooks() => select(videoBooks).get();

  // ── video_scrape_meta（条目刮削资料，v54）─────────────────────────

  /// 写入/覆盖一本视频的刮削资料（bookUid 主键，重刮即覆盖）。
  Future<void> upsertVideoScrapeMeta(VideoScrapeMetaCompanion meta) =>
      into(videoScrapeMeta).insertOnConflictUpdate(meta);

  /// 取单本刮削资料；未刮过返回 null。
  Future<VideoScrapeMetaRow?> getVideoScrapeMeta(String bookUid) =>
      (select(videoScrapeMeta)
            ..where(($VideoScrapeMetaTable t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  /// 已刮削过的 bookUid 集合。自动刮削扫描用它一次性排除已刮的，避免逐本查询
  /// （N+1）。返回 Set 供 O(1) 判断。
  Future<Set<String>> scrapedVideoBookUids() async {
    final List<VideoScrapeMetaRow> rows = await select(videoScrapeMeta).get();
    return <String>{
      for (final VideoScrapeMetaRow r in rows) r.bookUid,
    };
  }

  /// 删除单本刮削资料（用户「重新刮削」前先清，或纠错后作废）。
  Future<void> deleteVideoScrapeMeta(String bookUid) => (delete(videoScrapeMeta)
        ..where(($VideoScrapeMetaTable t) => t.bookUid.equals(bookUid)))
      .go();

  /// 全量条目刮削资料（TODO-2486 视频首页年份筛选）。库页一次拉全表内存建
  /// uid → 行映射，替代逐本 [getVideoScrapeMeta] 的 N+1。
  Future<List<VideoScrapeMetaRow>> getAllVideoScrapeMeta() =>
      select(videoScrapeMeta).get();

  // ── collection_scrape_meta（合集级刮削资料，schema v64 / BUG-1310）────────

  /// 写入/覆盖合集刮削资料（同 collectionId 覆盖，重刮即替换）。
  Future<void> upsertCollectionScrapeMeta(CollectionScrapeMetaCompanion meta) =>
      into(collectionScrapeMeta).insertOnConflictUpdate(meta);

  /// 取合集刮削资料；未刮过返回 null（详情页据此回落到「只有标题 + 进度」的旧形态）。
  Future<CollectionScrapeMetaRow?> getCollectionScrapeMeta(int collectionId) =>
      (select(collectionScrapeMeta)
            ..where(($CollectionScrapeMetaTable t) =>
                t.collectionId.equals(collectionId)))
          .getSingleOrNull();

  /// 监听单个合集的刮削资料。详情页据此在刮削落库后自动重建 hero，无需手动刷新
  /// （与合集封面同一次写入事务，用户点「使用」后资料与背景图一起出现）。
  Stream<CollectionScrapeMetaRow?> watchCollectionScrapeMeta(
          int collectionId) =>
      (select(collectionScrapeMeta)
            ..where(($CollectionScrapeMetaTable t) =>
                t.collectionId.equals(collectionId)))
          .watchSingleOrNull();

  /// 全量合集刮削资料（TODO-2486 视频首页 hero 轮播：backdrop / 简介 / airDate）。
  /// 首页一次拉全表内存建 collectionId → 行映射，替代逐合集查询的 N+1。
  Future<List<CollectionScrapeMetaRow>> getAllCollectionScrapeMeta() =>
      select(collectionScrapeMeta).get();

  /// 删除合集刮削资料（「重新刮削」前先清，或纠错后作废）。
  Future<void> deleteCollectionScrapeMeta(int collectionId) =>
      (delete(collectionScrapeMeta)
            ..where(($CollectionScrapeMetaTable t) =>
                t.collectionId.equals(collectionId)))
          .go();

  // ── collection_relations（合集相关作品，schema v66 / TODO-2484）──────

  /// 整体替换某合集的相关作品边（重刮即替换）。
  ///
  /// 事务内 delete + insert 而非逐条 upsert：关系列表来自源的一次完整响应，
  /// 逐条 upsert 会留下上次刮削已不存在的残边（源侧撤销的关联永远删不掉）。
  Future<void> replaceCollectionRelations(
    int collectionId,
    List<CollectionRelationsCompanion> relations,
  ) =>
      transaction(() async {
        await (delete(collectionRelations)
              ..where(($CollectionRelationsTable t) =>
                  t.collectionId.equals(collectionId)))
            .go();
        for (final CollectionRelationsCompanion c in relations) {
          await into(collectionRelations).insert(c);
        }
      });

  /// 按展示顺序（sortIndex → id）列出某合集的相关作品。
  Future<List<CollectionRelationRow>> getCollectionRelations(
    int collectionId,
  ) =>
      (select(collectionRelations)
            ..where(($CollectionRelationsTable t) =>
                t.collectionId.equals(collectionId))
            ..orderBy([
              ($CollectionRelationsTable t) =>
                  OrderingTerm(expression: t.sortIndex),
              ($CollectionRelationsTable t) => OrderingTerm(expression: t.id),
            ]))
          .get();

  /// 监听某合集的相关作品（详情页据此在刮削落库后自动出现该区块）。
  Stream<List<CollectionRelationRow>> watchCollectionRelations(
    int collectionId,
  ) =>
      (select(collectionRelations)
            ..where(($CollectionRelationsTable t) =>
                t.collectionId.equals(collectionId))
            ..orderBy([
              ($CollectionRelationsTable t) =>
                  OrderingTerm(expression: t.sortIndex),
              ($CollectionRelationsTable t) => OrderingTerm(expression: t.id),
            ]))
          .watch();

  /// 删除某合集的全部相关作品边（「重新刮削」前先清，或纠错后作废）。
  Future<void> deleteCollectionRelations(int collectionId) =>
      (delete(collectionRelations)
            ..where(($CollectionRelationsTable t) =>
                t.collectionId.equals(collectionId)))
          .go();

  /// 升级绑定：把一条纯刮削目标边绑定为本地合集（[targetCollectionId] 传 null
  /// 即解绑退回纯刮削态）。
  Future<void> bindCollectionRelationTarget(
    int relationId,
    int? targetCollectionId,
  ) =>
      (update(collectionRelations)
            ..where(($CollectionRelationsTable t) => t.id.equals(relationId)))
          .write(CollectionRelationsCompanion(
        targetCollectionId: Value<int?>(targetCollectionId),
      ));

  /// 反查：已把 (source, subjectId) 刮成资料的本地合集 id 列表（抓取层用它把
  /// 「纯刮削目标」自动升级绑定为本地合集）。
  Future<List<int>> collectionIdsByScrapeSubject(
    String source,
    String subjectId,
  ) async {
    final List<CollectionScrapeMetaRow> rows =
        await (select(collectionScrapeMeta)
              ..where(($CollectionScrapeMetaTable t) =>
                  t.source.equals(source) & t.subjectId.equals(subjectId)))
            .get();
    return <int>[for (final CollectionScrapeMetaRow r in rows) r.collectionId];
  }

  // ── media_images（媒体附加图组，schema v68 / Jellyfin 图组对齐）──────

  /// 整体替换某合集的附加图组（重刮即替换；空列表 = 清空）。
  ///
  /// 事务内 delete + insert（与 [replaceCollectionRelations] 同理由）：图组来自
  /// 源的一次完整响应，逐条 upsert 会留下上次刮削已不存在的残图行。
  Future<void> replaceMediaImagesForCollection(
    int collectionId,
    List<MediaImagesCompanion> images,
  ) =>
      transaction(() async {
        await (delete(mediaImages)
              ..where(
                  ($MediaImagesTable t) => t.collectionId.equals(collectionId)))
            .go();
        for (final MediaImagesCompanion c in images) {
          await into(mediaImages).insert(c);
        }
      });

  /// 整体替换某视频的附加图组（散装电影刮削用；空列表 = 清空）。
  Future<void> replaceMediaImagesForBook(
    String bookUid,
    List<MediaImagesCompanion> images,
  ) =>
      transaction(() async {
        await (delete(mediaImages)
              ..where(($MediaImagesTable t) => t.bookUid.equals(bookUid)))
            .go();
        for (final MediaImagesCompanion c in images) {
          await into(mediaImages).insert(c);
        }
      });

  /// 某合集的附加图组（kind 组内按 position 升序，backdrop 轮换序即此序）。
  Future<List<MediaImageRow>> getMediaImagesForCollection(int collectionId) =>
      (select(mediaImages)
            ..where(
                ($MediaImagesTable t) => t.collectionId.equals(collectionId))
            ..orderBy([
              ($MediaImagesTable t) => OrderingTerm(expression: t.kind),
              ($MediaImagesTable t) => OrderingTerm(expression: t.position),
            ]))
          .get();

  /// 某视频的附加图组。
  Future<List<MediaImageRow>> getMediaImagesForBook(String bookUid) =>
      (select(mediaImages)
            ..where(($MediaImagesTable t) => t.bookUid.equals(bookUid))
            ..orderBy([
              ($MediaImagesTable t) => OrderingTerm(expression: t.kind),
              ($MediaImagesTable t) => OrderingTerm(expression: t.position),
            ]))
          .get();

  /// 全表附加图组（库页/首页批量预取，替代逐归属查询的 N+1；调用方按
  /// collectionId / bookUid 内存分组）。
  Future<List<MediaImageRow>> getAllMediaImages() => (select(mediaImages)
        ..orderBy([
          ($MediaImagesTable t) => OrderingTerm(expression: t.kind),
          ($MediaImagesTable t) => OrderingTerm(expression: t.position),
        ]))
      .get();

  /// 监听视频库 uid 集合。插入/删除行时发出更新后的 uid 列表；库页据此在任意
  /// 导入路径（页内 / 拖拽 / 外部「用 Hibiki 打开」/ 远端下载）落库后自动重查，
  /// 无需每个调用点各自记得刷新（BUG-793）。注意 Drift 的表级失效会让纯列更新
  /// （封面回写、播放进度）也触发本流，故消费方按集合是否变化去重，避免自愈
  /// 写回引发的重刷环。
  /// BUG-793/BUG-834：监听 videoBooks 集合变化改用 [tableUpdates] 手动重查，而非 drift
  /// keyed `.watch()`。keyed 查询流在最后一个订阅取消时会安排一个缓存保留 `Timer.run`
  /// （drift 内部「多留一会缓存」优化）；真机上它下一拍即触发无害，但在 widget 测试里页面
  /// dispose 取消订阅后该 Timer 仍 pending，触发 flutter_test `!timersPending` 断言并让
  /// flutter_tester isolate 永不退出（BUG-834：所有挂载 HomeVideoPage 的 suite 挂死、
  /// CI 全量单测卡 60min）。[tableUpdates] 流不是 QueryStream、取消时不走 markAsClosed、
  /// 不安排该 Timer，故切走视频页不再遗留孤儿 async。消费方（`_onVideoUidsChanged`）按
  /// 集合去重，表内非集合变更（进度/封面回写）触发的额外重查无害。
  Stream<List<String>> watchVideoBookUids() {
    Future<List<String>> currentUids() async => (await select(videoBooks).get())
        .map((VideoBookRow row) => row.bookUid)
        .toList();
    late final StreamController<List<String>> controller;
    StreamSubscription<void>? updatesSub;
    controller = StreamController<List<String>>(
      onListen: () {
        // 初始 emit：等同旧 drift keyed `.watch()` 首发，库页首次加载不回归。
        currentUids().then((List<String> v) {
          if (!controller.isClosed) controller.add(v);
        });
        // 表级变更重查：BUG-793 自动刷新保留。
        updatesSub =
            tableUpdates(TableUpdateQuery.onTable(videoBooks)).listen((_) {
          currentUids().then((List<String> v) {
            if (!controller.isClosed) controller.add(v);
          });
        });
      },
      // BUG-834 follow-up：async* + `await for` 广播流的订阅 cancel() 永不完成，
      // 让 flutter_test 的 awaited tearDown 挂死超时。改为手动 StreamController，
      // onCancel 里 await 内层 listen 订阅的 cancel()（会正常完成），使取消收敛。
      onCancel: () async {
        await updatesSub?.cancel();
      },
    );
    return controller.stream;
  }

  Future<void> updateVideoBookPosition(String bookUid, int positionMs) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(lastPositionMs: Value(positionMs)));

  Future<void> updateVideoBookEpisode(String bookUid, int episodeIndex) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(currentEpisode: Value(episodeIndex)));

  /// 回写整段播放列表 JSON（各集 positionMs 改变时持久化每集进度）。
  Future<void> updateVideoBookPlaylistJson(
          String bookUid, String playlistJson) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(playlistJson: Value(playlistJson)));

  /// 更新音画延迟（毫秒）：字幕 cue 同步偏移，跨重启保留。
  Future<void> updateVideoBookDelayMs(String bookUid, int delayMs) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(delayMs: Value(delayMs)));

  /// 更新用户选中的字幕源（外挂存路径；内嵌存 `embedded:<n>`；关闭存 null）。
  Future<void> updateVideoBookSubtitleSource(
          String bookUid, String? subtitleSource) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(subtitleSource: Value(subtitleSource)));

  /// 更新用户选中的副字幕源（TODO-857）：与 [updateVideoBookSubtitleSource] 同款
  /// 四态编码（外挂路径 / `embedded:<n>` / `off:` / null）。
  Future<void> updateVideoBookSecondarySubtitleSource(
          String bookUid, String? secondarySubtitleSource) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid))).write(
          VideoBooksCompanion(
              secondarySubtitleSource: Value(secondarySubtitleSource)));

  /// 更新用户选中的音轨 id（libmpv `AudioTrack.id`；清除存 null）。
  Future<void> updateVideoBookAudioTrackId(
          String bookUid, String? audioTrackId) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(audioTrackId: Value(audioTrackId)));

  /// 更新视频封面图绝对路径（用户在书架/视频库长按菜单手动设置）。
  Future<void> updateVideoBookCover(String bookUid, String coverPath) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(coverPath: Value(coverPath)));

  /// 清空视频封面图路径（回落到「无封面」占位）。
  ///
  /// 与 [updateVideoBookCover] 分开而不是给它塞 null：清空是**独立动作**（存量
  /// 子篇作品海报摘除，见 `member_cover_cleanup.dart`），可空参数会让「忘了传」
  /// 和「有意清空」在类型上无法区分。
  Future<void> clearVideoBookCover(String bookUid) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(const VideoBooksCompanion(coverPath: Value<String?>(null)));

  /// 更新视频/播放列表标题（用户在视频库长按菜单「重命名」）。title 列已存在，
  /// 无 schema 变更。
  Future<void> updateVideoBookTitle(String bookUid, String title) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(title: Value(title)));

  /// 删除视频书：FK `onDelete: cascade` 自动清掉它在 video_book_tag_mappings 的
  /// 标签映射；audio_cues 的 bookKey 不是外键（它对有声书/SRT/视频共用一个字符串
  /// owner key，无法挂 FK），故必须在同一事务里显式删掉本视频的字幕 cue 行
  /// （BUG-276：否则删视频后 cue 行永久残留，删一本占用却不降）。
  Future<void> deleteVideoBook(String bookUid) => transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookUid))).go();
        // TODO-616：同事务清 shelf_entry（mediaType='video'、entryKey=bookUid）。
        await deleteShelfEntry(MediaKind.video, bookUid);
        await (delete(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
            .go();
      });

  // ── media_sources ───────────────────────────────────────────────
  // TODO-817：网络/本地来源库 CRUD。configJson 绝不裸存明文密码（本地恒 NULL，
  // 网络只存凭据引用键，密码本体 M3 才落）。

  /// 插入一条来源，返回自增 id。
  Future<int> insertMediaSource(MediaSourcesCompanion source) =>
      into(mediaSources).insert(source);

  /// 全部来源，按 sortOrder 升序、id 升序（列表稳定排序）。
  Future<List<MediaSourceRow>> getAllMediaSources() => (select(mediaSources)
        ..orderBy([
          (t) => OrderingTerm(expression: t.sortOrder),
          (t) => OrderingTerm(expression: t.id),
        ]))
      .get();

  /// 按媒体种类（'video' | 'book'）过滤，仍按 sortOrder、id 升序。
  Future<List<MediaSourceRow>> getMediaSourcesByKind(String mediaKind) =>
      (select(mediaSources)
            ..where((t) => t.mediaKind.equals(mediaKind))
            ..orderBy([
              (t) => OrderingTerm(expression: t.sortOrder),
              (t) => OrderingTerm(expression: t.id),
            ]))
          .get();

  /// 按 id 取单条来源（不存在返回 null）。
  Future<MediaSourceRow?> getMediaSourceById(int id) =>
      (select(mediaSources)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 删除来源：依赖 FK onDelete:setNull，归属本来源的 video_books / epub_books
  /// 自动把 source_id 归 NULL（条目保留，不连坐删）。返回删除行数。
  Future<int> deleteMediaSource(int id) =>
      (delete(mediaSources)..where((t) => t.id.equals(id))).go();

  /// 回写一次扫描结果（媒体数 / 时间 / 失败原因）。
  Future<void> updateMediaSourceScanResult({
    required int id,
    required int mediaCount,
    required DateTime lastScannedAt,
    String? lastScanError,
  }) =>
      (update(mediaSources)..where((t) => t.id.equals(id))).write(
        MediaSourcesCompanion(
          mediaCount: Value(mediaCount),
          lastScannedAt: Value(lastScannedAt),
          lastScanError: Value(lastScanError),
        ),
      );

  /// 统计某来源当前**累计拥有**的媒体条目数（TODO-1036）。
  ///
  /// [mediaCount] 列记的是「上次扫描新增条目数」（去重跳过的已存在书不计），
  /// 不能当总数显示。这里直接 COUNT 反向指向本来源的 epub_books / video_books
  /// 行：[mediaKind]=='book' → epub_books，'video' → video_books，
  /// 'manga' → epub_books 中 `format='manga'` 的漫画行（漫画与书是不同的
  /// MediaSources 行，sourceId 天然互不污染；format 过滤只是把值域契约显式化），
  /// 其它种类返回 0。
  Future<int> countMediaBySourceId(int sourceId, String mediaKind) async {
    final Expression<int> cnt = countAll();
    if (mediaKind == 'book') {
      final TypedResult row = await (selectOnly(epubBooks)
            ..where(epubBooks.sourceId.equals(sourceId))
            ..addColumns(<Expression<Object>>[cnt]))
          .getSingle();
      return row.read(cnt) ?? 0;
    }
    if (mediaKind == 'manga') {
      final TypedResult row = await (selectOnly(epubBooks)
            ..where(epubBooks.sourceId.equals(sourceId) &
                epubBooks.format.equals('manga'))
            ..addColumns(<Expression<Object>>[cnt]))
          .getSingle();
      return row.read(cnt) ?? 0;
    }
    if (mediaKind == 'video') {
      final TypedResult row = await (selectOnly(videoBooks)
            ..where(videoBooks.sourceId.equals(sourceId))
            ..addColumns(<Expression<Object>>[cnt]))
          .getSingle();
      return row.read(cnt) ?? 0;
    }
    return 0;
  }

  /// 更新来源显示名。
  Future<void> updateMediaSourceLabel(int id, String label) =>
      (update(mediaSources)..where((t) => t.id.equals(id)))
          .write(MediaSourcesCompanion(label: Value(label)));

  /// 更新来源排序权重（来源库 UI 拖拽重排后逐行回写，与 [getAllMediaSources] /
  /// [getMediaSourcesByKind] 的 orderBy(sortOrder, id) 对齐）。只写 sortOrder 列，
  /// 不动其它字段。
  Future<void> updateMediaSourceSortOrder(int id, int sortOrder) =>
      (update(mediaSources)..where((t) => t.id.equals(id)))
          .write(MediaSourcesCompanion(sortOrder: Value(sortOrder)));

  // ── Mihon manga extensions (v63) ───────────────────────────────

  Future<List<MangaExtensionStoreRow>> getMangaExtensionStores() =>
      (select(mangaExtensionStores)
            ..orderBy([
              (t) => OrderingTerm(expression: t.sortOrder),
              (t) => OrderingTerm(expression: t.indexUrl),
            ]))
          .get();

  Future<void> upsertMangaExtensionStore(MangaExtensionStoresCompanion store) =>
      into(mangaExtensionStores).insertOnConflictUpdate(store);

  Future<int> deleteMangaExtensionStore(String indexUrl) =>
      (delete(mangaExtensionStores)..where((t) => t.indexUrl.equals(indexUrl)))
          .go();

  Future<List<MangaExtensionRow>> getMangaExtensions() =>
      (select(mangaExtensions)
            ..orderBy([
              (t) => OrderingTerm(expression: t.name),
              (t) => OrderingTerm(expression: t.packageName),
            ]))
          .get();

  Future<MangaExtensionRow?> getMangaExtension(String packageName) =>
      (select(mangaExtensions)..where((t) => t.packageName.equals(packageName)))
          .getSingleOrNull();

  Future<void> upsertMangaExtension(MangaExtensionsCompanion extension) =>
      into(mangaExtensions).insertOnConflictUpdate(extension);

  Future<void> setMangaExtensionEnabled(String packageName, bool enabled) =>
      (update(mangaExtensions)..where((t) => t.packageName.equals(packageName)))
          .write(MangaExtensionsCompanion(enabled: Value(enabled)));

  Future<void> deleteMangaExtension(String packageName) =>
      transaction(() async {
        await (delete(mangaSourcePreferences)
              ..where((t) => t.extensionPackage.equals(packageName)))
            .go();
        await (delete(mangaOnlineSources)
              ..where((t) => t.extensionPackage.equals(packageName)))
            .go();
        await (delete(mangaExtensions)
              ..where((t) => t.packageName.equals(packageName)))
            .go();
      });

  Future<List<MangaOnlineSourceRow>> getMangaOnlineSources() =>
      (select(mangaOnlineSources)
            ..orderBy([
              (t) => OrderingTerm(
                    expression: t.pinned,
                    mode: OrderingMode.desc,
                  ),
              (t) => OrderingTerm(expression: t.sortOrder),
              (t) => OrderingTerm(expression: t.name),
            ]))
          .get();

  Future<void> replaceMangaOnlineSources(
    String packageName,
    Iterable<MangaOnlineSourcesCompanion> sources,
  ) =>
      transaction(() async {
        final List<MangaOnlineSourceRow> previous =
            await (select(mangaOnlineSources)
                  ..where((t) => t.extensionPackage.equals(packageName)))
                .get();
        final Map<String, MangaOnlineSourceRow> settings =
            <String, MangaOnlineSourceRow>{
          for (final MangaOnlineSourceRow row in previous) row.sourceId: row,
        };
        await (delete(mangaOnlineSources)
              ..where((t) => t.extensionPackage.equals(packageName)))
            .go();
        for (final MangaOnlineSourcesCompanion source in sources) {
          final String? sourceId =
              source.sourceId.present ? source.sourceId.value : null;
          final MangaOnlineSourceRow? old =
              sourceId == null ? null : settings[sourceId];
          await into(mangaOnlineSources).insert(
            source.copyWith(
              enabled: old == null ? source.enabled : Value(old.enabled),
              pinned: old == null ? source.pinned : Value(old.pinned),
              sortOrder: old == null ? source.sortOrder : Value(old.sortOrder),
            ),
          );
        }
      });

  Future<void> updateMangaOnlineSourceSettings({
    required String extensionPackage,
    required String sourceId,
    bool? enabled,
    bool? pinned,
    int? sortOrder,
  }) =>
      (update(mangaOnlineSources)
            ..where((t) =>
                t.extensionPackage.equals(extensionPackage) &
                t.sourceId.equals(sourceId)))
          .write(
        MangaOnlineSourcesCompanion(
          enabled: enabled == null ? const Value.absent() : Value(enabled),
          pinned: pinned == null ? const Value.absent() : Value(pinned),
          sortOrder:
              sortOrder == null ? const Value.absent() : Value(sortOrder),
        ),
      );

  Future<List<MangaSourcePreferenceRow>> getMangaSourcePreferences(
    String extensionPackage,
    String sourceId,
  ) =>
      (select(mangaSourcePreferences)
            ..where((t) =>
                t.extensionPackage.equals(extensionPackage) &
                t.sourceId.equals(sourceId))
            ..orderBy([(t) => OrderingTerm(expression: t.preferenceKey)]))
          .get();

  Future<void> upsertMangaSourcePreference(
          MangaSourcePreferencesCompanion preference) =>
      into(mangaSourcePreferences).insertOnConflictUpdate(preference);

  Future<void> clearMangaSourcePreferences(
    String extensionPackage,
    String sourceId,
  ) =>
      (delete(mangaSourcePreferences)
            ..where((t) =>
                t.extensionPackage.equals(extensionPackage) &
                t.sourceId.equals(sourceId)))
          .go();

  Future<List<MangaTrustedSignerRow>> getMangaTrustedSigners() =>
      select(mangaTrustedSigners).get();

  Future<bool> isMangaSignerTrusted(String fingerprint) async =>
      await (select(mangaTrustedSigners)
            ..where((t) => t.fingerprint.equals(fingerprint)))
          .getSingleOrNull() !=
      null;

  Future<void> trustMangaSigner(MangaTrustedSignersCompanion signer) =>
      into(mangaTrustedSigners).insertOnConflictUpdate(signer);

  // ── fushi_paired_peers (TODO-1017 阶段1) ────────────────────────
  // 互联 per-peer 授权凭据 CRUD。🔴 token 是敏感凭据（明文列存，方案待定），
  // 绝不写日志、绝不进 sync/backup 明文导出。

  /// 全部已配对对端，按 pairedAtMs 升序（配对先后稳定排序）、id 升序兜底同戳。
  Future<List<FushiPairedPeerRow>> getPairedPeers() => (select(fushiPairedPeers)
        ..orderBy([
          (t) => OrderingTerm(expression: t.pairedAtMs),
          (t) => OrderingTerm(expression: t.id),
        ]))
      .get();

  /// 按 peerId 幂等 upsert（存在则整行更新）。ON CONFLICT 目标必须显式指定
  /// [peerId]（非主键 id）：不指定时 drift 默认按主键 id 冲突，而 upsert 契约是
  /// 按 peerId 认定同一设备（id 自增每次不同），会误撞 peerId UNIQUE 抛错。
  /// 重复配对同一设备只更新其 token / deviceName / lastSeenIp，不新增行。
  Future<void> upsertPairedPeer(FushiPairedPeersCompanion peer) =>
      into(fushiPairedPeers).insert(peer,
          onConflict: DoUpdate((_) => peer, target: [fushiPairedPeers.peerId]));

  /// 吊销一台已配对设备（按 peerId 删行），返回删除的行数（0 = 无此对端）。
  Future<int> revokePairedPeer(String peerId) =>
      (delete(fushiPairedPeers)..where((t) => t.peerId.equals(peerId))).go();

  // ── series (TODO-616 A) ─────────────────────────────────────────
  /// 全部系列，按 sortOrder 升序、id 升序（卡片列表稳定排序）。
  Future<List<SeriesRow>> getAllSeries() => (select(series)
        ..orderBy([
          (t) => OrderingTerm(expression: t.sortOrder),
          (t) => OrderingTerm(expression: t.id),
        ]))
      .get();

  /// 新建系列，返回自增 id。createdAt 用当前毫秒戳，sortOrder 默认排到末尾
  /// （现有最大 sortOrder + 1，空表为 0）。
  Future<int> createSeries(String name) => transaction(() async {
        final int nextOrder = await _nextSeriesSortOrder();
        return into(series).insert(SeriesCompanion.insert(
          name: name,
          sortOrder: Value(nextOrder),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      });

  Future<int> _nextSeriesSortOrder() async {
    final SeriesRow? last = await (select(series)
          ..orderBy([(t) => OrderingTerm.desc(t.sortOrder)])
          ..limit(1))
        .getSingleOrNull();
    return last == null ? 0 : last.sortOrder + 1;
  }

  /// 改系列名（只写 name 列）。
  Future<void> updateSeriesName(int id, String name) =>
      (update(series)..where((t) => t.id.equals(id)))
          .write(SeriesCompanion(name: Value(name)));

  /// 改系列卡片排序权重（拖拽重排后逐行回写，与 [getAllSeries] orderBy 对齐）。
  Future<void> updateSeriesSortOrder(int id, int sortOrder) =>
      (update(series)..where((t) => t.id.equals(id)))
          .write(SeriesCompanion(sortOrder: Value(sortOrder)));

  /// 删系列：依赖 FK onDelete:setNull，归属本系列的 shelf_entries 自动把 seriesId
  /// 归 NULL（成员散回书架，不连坐删条目）。返回删除行数。
  Future<int> deleteSeries(int id) =>
      (delete(series)..where((t) => t.id.equals(id))).go();

  // ── shelf_entries (TODO-616 B 排序 + A 归属) ─────────────────────
  /// 取单条目映射行（不存在返回 null）。
  Future<ShelfEntryRow?> getShelfEntry(MediaKind mediaType, String entryKey) =>
      (select(shelfEntries)
            ..where((t) =>
                t.mediaType.equals(mediaType.dbValue) &
                t.entryKey.equals(entryKey)))
          .getSingleOrNull();

  /// 全部映射行（渲染层一次性批量预取，内存 join 三表 + 远端列表，避免 N+1）。
  Future<List<ShelfEntryRow>> getAllShelfEntries() =>
      select(shelfEntries).get();

  /// 某系列下的全部成员映射行。
  Future<List<ShelfEntryRow>> getShelfEntriesBySeries(int seriesId) =>
      (select(shelfEntries)..where((t) => t.seriesId.equals(seriesId))).get();

  /// 拖拽回写排序权重，按需建行：已有行只改 sortOrder（**不动 seriesId**，部分
  /// 更新避免清空已有归属）；无行则插一条 seriesId=NULL 的新行。
  Future<void> upsertShelfOrder(
          MediaKind mediaType, String entryKey, int sortOrder) =>
      transaction(() async {
        final int updated = await (update(shelfEntries)
              ..where((t) =>
                  t.mediaType.equals(mediaType.dbValue) &
                  t.entryKey.equals(entryKey)))
            .write(ShelfEntriesCompanion(sortOrder: Value(sortOrder)));
        if (updated == 0) {
          await into(shelfEntries).insert(ShelfEntriesCompanion.insert(
            mediaType: mediaType.dbValue,
            entryKey: entryKey,
            sortOrder: Value(sortOrder),
          ));
        }
      });

  /// 批量回写排序权重（退出重排页时一次落盘）：单事务内逐条 update-or-insert，
  /// 避免逐条 [upsertShelfOrder] 的 N 次小事务开销。每个三元组
  /// `(mediaType, entryKey, sortOrder)` 语义同 [upsertShelfOrder]（只改 sortOrder
  /// 不动 seriesId，部分更新保归属）。
  Future<void> batchUpsertShelfOrder(
          List<({MediaKind mediaType, String entryKey, int sortOrder})>
              orders) =>
      transaction(() async {
        for (final ({MediaKind mediaType, String entryKey, int sortOrder}) o
            in orders) {
          final int updated = await (update(shelfEntries)
                ..where((t) =>
                    t.mediaType.equals(o.mediaType.dbValue) &
                    t.entryKey.equals(o.entryKey)))
              .write(ShelfEntriesCompanion(sortOrder: Value(o.sortOrder)));
          if (updated == 0) {
            await into(shelfEntries).insert(ShelfEntriesCompanion.insert(
              mediaType: o.mediaType.dbValue,
              entryKey: o.entryKey,
              sortOrder: Value(o.sortOrder),
            ));
          }
        }
      });

  /// 设/清条目归属系列（[seriesId] 为 null = 移出系列）。按需建行；已有行只改
  /// seriesId（**不动 sortOrder**，部分更新避免重置已有排序）。
  Future<void> setSeriesForEntry(
          MediaKind mediaType, String entryKey, int? seriesId) =>
      transaction(() async {
        final int updated = await (update(shelfEntries)
              ..where((t) =>
                  t.mediaType.equals(mediaType.dbValue) &
                  t.entryKey.equals(entryKey)))
            .write(ShelfEntriesCompanion(seriesId: Value(seriesId)));
        if (updated == 0) {
          await into(shelfEntries).insert(ShelfEntriesCompanion.insert(
            mediaType: mediaType.dbValue,
            entryKey: entryKey,
            seriesId: Value(seriesId),
          ));
        }
      });

  /// 幂等删一条目映射行（删 0 行不报错）。四个删书 DAO 方法的 transaction() 体内
  /// 同事务调用（TODO-616 §0🔴3），删 shelf_entry 与删书行真原子。
  Future<int> deleteShelfEntry(MediaKind mediaType, String entryKey) =>
      (delete(shelfEntries)
            ..where((t) =>
                t.mediaType.equals(mediaType.dbValue) &
                t.entryKey.equals(entryKey)))
          .go();

  /// 远端书下载后 bookKey 漂移的改键迁移（TODO-616 §0🔴2）：独立事务，读旧行 →
  /// 若新行不存在则改键写（沿用旧行 sortOrder/seriesId）→ 删旧行；新行已存在则本地
  /// 优先不覆盖、仅删旧行。等键 / 无旧行 no-op。
  Future<void> migrateShelfEntryKey(
          MediaKind mediaType, String oldEntryKey, String newEntryKey) =>
      transaction(() async {
        if (oldEntryKey == newEntryKey) return;
        final ShelfEntryRow? oldRow =
            await getShelfEntry(mediaType, oldEntryKey);
        if (oldRow == null) return;
        final ShelfEntryRow? newRow =
            await getShelfEntry(mediaType, newEntryKey);
        if (newRow == null) {
          await into(shelfEntries).insert(ShelfEntriesCompanion.insert(
            mediaType: mediaType.dbValue,
            entryKey: newEntryKey,
            sortOrder: Value(oldRow.sortOrder),
            seriesId: Value(oldRow.seriesId),
          ));
        }
        // 新行已存在 → 本地优先不覆盖，仅删旧行（下面统一删）。
        await (delete(shelfEntries)
              ..where((t) =>
                  t.mediaType.equals(mediaType.dbValue) &
                  t.entryKey.equals(oldEntryKey)))
            .go();
      });

  // ── media collections (统一合集：Jellyfin 式容器 + 成员引用) ─────────
  /// 全部合集，按 sortOrder 升序、id 升序（卡片列表稳定排序，同 [getAllSeries] 范式）。
  Future<List<MediaCollectionRow>> getAllMediaCollections() =>
      (select(mediaCollections)
            ..orderBy([
              (t) => OrderingTerm(expression: t.sortOrder),
              (t) => OrderingTerm(expression: t.id),
            ]))
          .get();

  Future<MediaCollectionRow?> getMediaCollectionById(int id) =>
      (select(mediaCollections)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  /// 绑定/清除合集的 AniList 系列 id（schema v45，字幕批量下载用）。[anilistId] 为 null
  /// 时清除绑定（回退合集名现解析）。
  Future<void> setMediaCollectionAnilistId(int id, int? anilistId) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
        MediaCollectionsCompanion(anilistId: Value<int?>(anilistId)),
      );

  /// 更新系列（合集）级音轨偏好（schema v52，恢复同系列音轨记忆）。[audioTrackId]
  /// 为 null 时清除（加载回退各集 per-book / libmpv 默认）。
  Future<void> updateMediaCollectionAudioTrackId(
          int id, String? audioTrackId) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
        MediaCollectionsCompanion(audioTrackId: Value<String?>(audioTrackId)),
      );

  /// 更新系列（合集）级字幕调轴（音画延迟毫秒，schema v52，恢复同系列调轴记忆）。
  /// [delayMs] 为 null 时清除（加载回退各集 per-book / 0）。
  Future<void> updateMediaCollectionSubtitleDelayMs(int id, int? delayMs) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
        MediaCollectionsCompanion(subtitleDelayMs: Value<int?>(delayMs)),
      );

  /// 新建合集，返回自增 id。sortOrder 默认排末尾（现有最大 +1，空表 0）。同事务清
  /// 同自然键的合集级删除墓碑（重建 = 撤销删除，仿插书清书墓碑 [insertEpubBook]
  /// 一律；不清成员墓碑——成员重加走 [addToCollection] 逐键清）。
  Future<int> createMediaCollection(String name,
          {String collectionType = 'collection'}) =>
      transaction(() async {
        // 先按自然键查重：已存在同 (name, collectionType) 行则复用其 id，绝不再造重复
        // 自然键行（否则同名两行让合集同步引擎每轮判不一致永不收敛，BUG 修复）。
        final MediaCollectionRow? existing =
            await getMediaCollectionByNaturalKey(name, collectionType);
        if (existing != null) return existing.id;
        final int nextOrder = await _nextMediaCollectionSortOrder();
        await (delete(collectionMemberTombstones)
              ..where((t) =>
                  t.collectionName.equals(name) &
                  t.collectionType.equals(collectionType) &
                  t.mediaType.equals(collectionTombstoneSentinel) &
                  t.entryKey.equals(collectionTombstoneSentinel)))
            .go();
        return into(mediaCollections).insert(MediaCollectionsCompanion.insert(
          name: name,
          collectionType: Value(collectionType),
          sortOrder: Value(nextOrder),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      });

  Future<int> _nextMediaCollectionSortOrder() async {
    final MediaCollectionRow? last = await (select(mediaCollections)
          ..orderBy([(t) => OrderingTerm.desc(t.sortOrder)])
          ..limit(1))
        .getSingleOrNull();
    return last == null ? 0 : last.sortOrder + 1;
  }

  /// 改合集名（改 name 列 + 维护跨端合集同步墓碑）。
  ///
  /// 跨端合集是成员/合集**并集**同步：只改 name 而不给旧自然键写合集级墓碑、不清新
  /// 键哨兵，会让「改一次名」在全网多出一个旧名副本永不自愈（旧名在对端并集里复活）。
  /// 故改名事务 = 改 name + 旧 (oldName,type) 清墓碑后写哨兵（同 deleteMediaCollection，
  /// 让对端删掉旧名副本）+ 清新 (name,type) 哨兵墓碑（同 createMediaCollection，
  /// 让新名不被自己旧删除墓碑秒杀）。改成同名(no-op)或目标 id 不存在时不动墓碑。
  Future<void> renameMediaCollection(int id, String name) =>
      transaction(() async {
        final MediaCollectionRow? col = await getMediaCollectionById(id);
        if (col == null || col.name == name) {
          await (update(mediaCollections)..where((t) => t.id.equals(id)))
              .write(MediaCollectionsCompanion(name: Value(name)));
          return;
        }
        final String oldName = col.name;
        final String type = col.collectionType;
        await (update(mediaCollections)..where((t) => t.id.equals(id)))
            .write(MediaCollectionsCompanion(name: Value(name)));
        // 旧 (oldName, type)：清其全部墓碑，只留合集级哨兵（镜像删除，让对端删旧名副本）。
        await (delete(collectionMemberTombstones)
              ..where((t) =>
                  t.collectionName.equals(oldName) &
                  t.collectionType.equals(type)))
            .go();
        await upsertCollectionMemberTombstone(
          collectionName: oldName,
          collectionType: type,
          mediaType: collectionTombstoneSentinel,
          entryKey: collectionTombstoneSentinel,
          deletedAt: DateTime.now().millisecondsSinceEpoch,
        );
        // 新 (name, type)：清其合集级哨兵墓碑（否则新名会被自己旧删除墓碑秒杀）。
        await (delete(collectionMemberTombstones)
              ..where((t) =>
                  t.collectionName.equals(name) &
                  t.collectionType.equals(type) &
                  t.mediaType.equals(collectionTombstoneSentinel) &
                  t.entryKey.equals(collectionTombstoneSentinel)))
            .go();
      });

  /// 改合集卡排序权重（拖拽重排后逐行回写）。
  Future<void> updateMediaCollectionSortOrder(int id, int sortOrder) =>
      (update(mediaCollections)..where((t) => t.id.equals(id)))
          .write(MediaCollectionsCompanion(sortOrder: Value(sortOrder)));

  /// 设/清自定义封面成员（null = 回到自动推导）。
  Future<void> updateMediaCollectionCover(int id, String? coverSource) =>
      (update(mediaCollections)..where((t) => t.id.equals(id)))
          .write(MediaCollectionsCompanion(coverSource: Value(coverSource)));

  /// 设/清**合集自有**封面图路径（[MediaCollections.coverPath]，schema v61）。
  ///
  /// 与 [updateMediaCollectionCover] 是两回事：那个记「借哪个成员的封面」，这个记
  /// 合集自己那张图的绝对路径。null = 清掉、回落成员借用链。
  /// **只写 media_collections 一行**——不碰任何 [VideoBooks] 成员（BUG-1211）。
  Future<void> updateMediaCollectionCoverPath(int id, String? coverPath) =>
      (update(mediaCollections)..where((t) => t.id.equals(id)))
          .write(MediaCollectionsCompanion(coverPath: Value(coverPath)));

  /// 删合集：显式先删本合集全部成员引用行、再删合集（不依赖 FK cascade，测试/生产
  /// 一致；绝不删条目本身）。返回删除的合集行数。同事务写合集级删除墓碑（空哨兵行，
  /// schema v40 防对端并集同步复活），并清本合集残留成员墓碑（合集已删，成员墓碑
  /// 无意义；留着会误杀日后重建同名合集时对端的成员）。
  Future<int> deleteMediaCollection(int id) => transaction(() async {
        final MediaCollectionRow? col = await getMediaCollectionById(id);
        await (delete(mediaCollectionItems)
              ..where((t) => t.collectionId.equals(id)))
            .go();
        final int deleted = await (delete(mediaCollections)
              ..where((t) => t.id.equals(id)))
            .go();
        if (col != null && deleted > 0) {
          await (delete(collectionMemberTombstones)
                ..where((t) =>
                    t.collectionName.equals(col.name) &
                    t.collectionType.equals(col.collectionType)))
              .go();
          await upsertCollectionMemberTombstone(
            collectionName: col.name,
            collectionType: col.collectionType,
            mediaType: collectionTombstoneSentinel,
            entryKey: collectionTombstoneSentinel,
            deletedAt: DateTime.now().millisecondsSinceEpoch,
          );
        }
        return deleted;
      });

  /// 某合集全部成员，按 sortIndex 升序、entryKey 升序、mediaType 升序（稳定播放/
  /// 展示序）。
  ///
  /// 三段排序键**恰好等于表的成员身份**（复合主键 `(collectionId, mediaType,
  /// entryKey)` 去掉已被 where 钉死的 collectionId）→ 全序，无并列。
  ///
  /// 末位 mediaType 段是**防御性**的，诚实说明其份量：只排到 entryKey 时，同一合集
  /// 里同 entryKey 的两个不同 mediaType 行（entryKey 是各域裸串——epub=bookKey /
  /// video=bookUid / game=galgames.id，命名空间不交叉是约定、不是 DB 约束）在
  /// sortIndex 也碰撞的情况下，次序就交给了查询计划。当前计划走复合主键索引扫描、
  /// 恰好已经是 mediaType 升序，所以补这一段**今天不改变任何可观测行为**——也因此
  /// 没有能检测其删除的行为测试，别为它编一个假绿守卫。写出来的理由是
  /// [reorderCollectionItems] 拿本查询的结果当槽位基准并**冻结**成永久的致密
  /// sortIndex：喂给冻结操作的读不该依赖计划的巧合。
  Future<List<MediaCollectionItemRow>> getCollectionItems(int collectionId) =>
      (select(mediaCollectionItems)
            ..where((t) => t.collectionId.equals(collectionId))
            ..orderBy([
              (t) => OrderingTerm(expression: t.sortIndex),
              (t) => OrderingTerm(expression: t.entryKey),
              (t) => OrderingTerm(expression: t.mediaType),
            ]))
          .get();

  /// 全部合集成员行（一次查询，供渲染层内存分组算组内 sortIndex，替代逐合集
  /// [getCollectionItems] 的 N+1）。按 collectionId、sortIndex、entryKey、mediaType
  /// 升序，与 [getCollectionItems] 同口径（含末位 mediaType 的全序兜底）——同一
  /// collectionId 的行连续且组内有序，调用方按
  /// [MediaCollectionItemRow.collectionId] 分组即等价于逐合集查。
  Future<List<MediaCollectionItemRow>> getAllCollectionItems() =>
      (select(mediaCollectionItems)
            ..orderBy([
              (t) => OrderingTerm(expression: t.collectionId),
              (t) => OrderingTerm(expression: t.sortIndex),
              (t) => OrderingTerm(expression: t.entryKey),
              (t) => OrderingTerm(expression: t.mediaType),
            ]))
          .get();

  /// `'<mediaType>|<entryKey>'` → 该条目所属的**最小** collectionId（折叠归属：库网格
  /// 里一条目折进 id 最小的合集卡；其余合集卡照常显示、详情页照常含该条目）。单查询
  /// GROUP BY MIN 避免 N+1。
  Future<Map<String, int>> getPrimaryCollectionIdByEntry() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT media_type, entry_key, MIN(collection_id) AS cid '
      'FROM media_collection_items GROUP BY media_type, entry_key',
    ).get();
    return <String, int>{
      for (final QueryRow r in rows)
        '${r.read<String>('media_type')}|${r.read<String>('entry_key')}':
            r.read<int>('cid'),
    };
  }

  Future<int> _nextCollectionSortIndex(int collectionId) async {
    final MediaCollectionItemRow? last = await (select(mediaCollectionItems)
          ..where((t) => t.collectionId.equals(collectionId))
          ..orderBy([(t) => OrderingTerm.desc(t.sortIndex)])
          ..limit(1))
        .getSingleOrNull();
    return last == null ? 0 : last.sortIndex + 1;
  }

  /// 加条目进合集（尾插；重复成员 INSERT OR IGNORE 幂等）。同事务清同键成员墓碑
  /// （schema v40：重新加入 = 撤销移出——否则跨端同步的成员墓碑会把刚加回的成员
  /// 再删掉，防复活变成禁重加）。
  ///
  /// P5：本机已知种类的类型化入口；转移/合并对端未知种类走 [addToCollectionRaw]。
  Future<void> addToCollection(
          int collectionId, MediaKind mediaType, String entryKey) =>
      addToCollectionRaw(collectionId, mediaType.dbValue, entryKey);

  /// [addToCollection] 的裸串版：合集合并/转移把**现有成员行原样搬家**时用——
  /// 行值可能是对端未来新增的未知种类（或旧值域残留），tryParse 丢弃会静默丢
  /// 成员（Never break userspace）。新增本机成员一律走类型化 [addToCollection]。
  Future<void> addToCollectionRaw(
          int collectionId, String mediaType, String entryKey) =>
      transaction(() async {
        final int next = await _nextCollectionSortIndex(collectionId);
        await into(mediaCollectionItems).insert(
          MediaCollectionItemsCompanion.insert(
            collectionId: collectionId,
            mediaType: mediaType,
            entryKey: entryKey,
            sortIndex: Value(next),
          ),
          mode: InsertMode.insertOrIgnore,
        );
        final MediaCollectionRow? col =
            await getMediaCollectionById(collectionId);
        if (col != null) {
          await deleteCollectionMemberTombstone(
            collectionName: col.name,
            collectionType: col.collectionType,
            mediaType: mediaType,
            entryKey: entryKey,
          );
        }
      });

  /// 移出成员；移空后自动删该合集（沿用旧 removeEntryFromSeries 语义，避免留 0 成员
  /// 孤儿合集卡）。同事务写成员移出墓碑（schema v40：跨端合集同步是成员并集，无墓碑
  /// 则本端移出的成员会被对端并集复活）。移空自删**不**写合集级墓碑：用户意图只是
  /// 移出成员，合集在对端若还有其它成员应继续存在（成员墓碑已足够收敛）。
  ///
  /// P5：本机已知种类的类型化入口；按成员**行值**移出（可能未知种类）走
  /// [removeFromCollectionRaw]。
  Future<void> removeFromCollection(
          int collectionId, MediaKind mediaType, String entryKey) =>
      removeFromCollectionRaw(collectionId, mediaType.dbValue, entryKey);

  /// [removeFromCollection] 的裸串版：详情页按现有成员行移出时，行值可能是对端
  /// 未来新增的未知种类——必须能原样移出，tryParse 丢弃会让该成员永远移不掉。
  Future<void> removeFromCollectionRaw(
          int collectionId, String mediaType, String entryKey) =>
      transaction(() async {
        final MediaCollectionRow? col =
            await getMediaCollectionById(collectionId);
        await (delete(mediaCollectionItems)
              ..where((t) =>
                  t.collectionId.equals(collectionId) &
                  t.mediaType.equals(mediaType) &
                  t.entryKey.equals(entryKey)))
            .go();
        if (col != null) {
          await upsertCollectionMemberTombstone(
            collectionName: col.name,
            collectionType: col.collectionType,
            mediaType: mediaType,
            entryKey: entryKey,
            deletedAt: DateTime.now().millisecondsSinceEpoch,
          );
        }
        final List<MediaCollectionItemRow> remaining =
            await (select(mediaCollectionItems)
                  ..where((t) => t.collectionId.equals(collectionId)))
                .get();
        if (remaining.isEmpty) {
          await (delete(mediaCollections)
                ..where((t) => t.id.equals(collectionId)))
              .go();
        }
      });

  /// 合集内重排：[ordered] 表达**它点名的那批成员之间的新相对顺序**，本方法负责把它
  /// 合并回全表并把 sortIndex 回写成致密 `0..n-1`（退出重排页一次落盘）。同事务 bump
  /// 本合集 orderUpdatedAt = now（schema v40 跨端手动序整合集 LWW 的比较键，只有真实
  /// 人为改序走这里；同步应用对端顺序走 [setCollectionOrderUpdatedAt] 镜像对端时间戳，
  /// 绝不 bump now——否则同步会伪装成更新的人为改序）。
  ///
  /// BUG-1194 根因修复——**不变量归 DAO 所有，不是各调用方的自觉**：
  /// 合集详情页天然只渲染成员子集（视频详情页按 mediaType 只显示 video；书架网格详情页
  /// 按标签过滤），而 `media_collection_items.mediaType` 无 CHECK 约束、一个合集可混多种
  /// 种类（「加入合集」弹窗列全表不按种类过滤；合集同步/备份合并按 `(name, collectionType)`
  /// 自然键对齐并原样并入对端裸串 mediaType，两端各建同名合集同步一轮即混合）。旧实现
  /// 直接按 [ordered] 的下标写 sortIndex：调用方只要传子集，未点名的成员就留着旧
  /// sortIndex 与新写的致密 `0..n-1` **碰撞**，[getCollectionItems] 平手退化按 entryKey
  /// 排，用户在网格详情页排好的跨种类顺序被打乱，还随同事务 bump 的 orderUpdatedAt 以
  /// LWW 赢家身份推给全部对端。修在页面里治标——每个现有和将来的调用方都得自己记得
  /// 合并；修在这里治本：**传子集是合法用法**，未点名的成员由本方法保证留在原槽位。
  ///
  /// 顺带自愈：任何一次重排都把全表写成致密序，历史遗留的碰撞 sortIndex 就此消除。
  /// 合并规则（含并发移出/重复键的容错）见 [mergeCollectionOrder]。
  Future<void> reorderCollectionItems(
          int collectionId, List<CollectionMemberKey> ordered) =>
      transaction(() async {
        // 事务内取当前全表顺序作槽位基准（[getCollectionItems] 的
        // sortIndex→entryKey→mediaType 全序 = 用户此刻看到的顺序；那三段键就是成员
        // 身份，无并列，故本次冻结出的致密序确定、不随查询计划变）。
        final List<MediaCollectionItemRow> all =
            await getCollectionItems(collectionId);
        final List<CollectionMemberKey> merged = mergeCollectionOrder(
          all: <CollectionMemberKey>[
            for (final MediaCollectionItemRow r in all)
              (mediaType: r.mediaType, entryKey: r.entryKey),
          ],
          subset: ordered,
          keyOf: (CollectionMemberKey k) => k,
        );
        for (int i = 0; i < merged.length; i++) {
          await (update(mediaCollectionItems)
                ..where((t) =>
                    t.collectionId.equals(collectionId) &
                    t.mediaType.equals(merged[i].mediaType) &
                    t.entryKey.equals(merged[i].entryKey)))
              .write(MediaCollectionItemsCompanion(sortIndex: Value(i)));
        }
        await (update(mediaCollections)
              ..where((t) => t.id.equals(collectionId)))
            .write(MediaCollectionsCompanion(
          orderUpdatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ));
      });

  /// 删条目时清其全部合集引用（逻辑外键无 DB cascade，删书路径主动调用）；被清空的
  /// 合集随之删除。
  Future<void> removeEntryFromAllCollections(
          MediaKind mediaType, String entryKey) =>
      transaction(() async {
        final List<MediaCollectionItemRow> affected =
            await (select(mediaCollectionItems)
                  ..where((t) =>
                      t.mediaType.equals(mediaType.dbValue) &
                      t.entryKey.equals(entryKey)))
                .get();
        if (affected.isEmpty) return;
        final Set<int> ids =
            affected.map((MediaCollectionItemRow e) => e.collectionId).toSet();
        await (delete(mediaCollectionItems)
              ..where((t) =>
                  t.mediaType.equals(mediaType.dbValue) &
                  t.entryKey.equals(entryKey)))
            .go();
        for (final int cid in ids) {
          final List<MediaCollectionItemRow> rem =
              await (select(mediaCollectionItems)
                    ..where((t) => t.collectionId.equals(cid)))
                  .get();
          if (rem.isEmpty) {
            await (delete(mediaCollections)..where((t) => t.id.equals(cid)))
                .go();
          }
        }
      });

  // ── collection tombstones (成员移出/合集删除墓碑, schema v40) ─────
  // 多端库联合视图 §2.3：合集跨端并集同步的防复活地基。表结构见
  // [CollectionMemberTombstones]（自然键 + 空哨兵行 = 合集级墓碑）。

  /// 合集级删除墓碑的哨兵值：mediaType 与 entryKey 皆为 ''（真实成员键恒非空，
  /// 无歧义）。
  static const String collectionTombstoneSentinel = '';

  /// 全部墓碑行（成员移出 + 合集级哨兵），同步引擎构建本地清单用。
  Future<List<CollectionMemberTombstoneRow>>
      getAllCollectionMemberTombstones() =>
          select(collectionMemberTombstones).get();

  /// 按自然键取合集行（同步应用端把清单自然键解析回本地自增 id）。表无 (name,
  /// collectionType) 唯一约束（历史 schema），万一重名取 id 最小行，与
  /// [getPrimaryCollectionIdByEntry] 的折叠方向一致。
  Future<MediaCollectionRow?> getMediaCollectionByNaturalKey(
          String name, String collectionType) =>
      (select(mediaCollections)
            ..where((t) =>
                t.name.equals(name) & t.collectionType.equals(collectionType))
            ..orderBy([(t) => OrderingTerm(expression: t.id)])
            ..limit(1))
          .getSingleOrNull();

  /// upsert 一条墓碑（重复移出刷新 deletedAt，单行 LWW）。
  Future<void> upsertCollectionMemberTombstone({
    required String collectionName,
    required String collectionType,
    required String mediaType,
    required String entryKey,
    required int deletedAt,
  }) =>
      into(collectionMemberTombstones).insertOnConflictUpdate(
        CollectionMemberTombstonesCompanion.insert(
          collectionName: collectionName,
          collectionType: collectionType,
          mediaType: mediaType,
          entryKey: entryKey,
          deletedAt: deletedAt,
        ),
      );

  /// 删一条成员墓碑（重新加入清墓碑；不存在 no-op）。
  Future<void> deleteCollectionMemberTombstone({
    required String collectionName,
    required String collectionType,
    required String mediaType,
    required String entryKey,
  }) =>
      (delete(collectionMemberTombstones)
            ..where((t) =>
                t.collectionName.equals(collectionName) &
                t.collectionType.equals(collectionType) &
                t.mediaType.equals(mediaType) &
                t.entryKey.equals(entryKey)))
          .go();

  /// 同步应用端专用：把某合集自然键下的全部墓碑行整体替换成 [rows]（本地墓碑
  /// 镜像合并后清单；是否含合集级哨兵行由 rows 决定）。事务内先删后插，幂等。
  Future<void> replaceCollectionTombstonesFor(
    String collectionName,
    String collectionType,
    List<CollectionMemberTombstonesCompanion> rows,
  ) =>
      transaction(() async {
        await (delete(collectionMemberTombstones)
              ..where((t) =>
                  t.collectionName.equals(collectionName) &
                  t.collectionType.equals(collectionType)))
            .go();
        for (final CollectionMemberTombstonesCompanion row in rows) {
          await into(collectionMemberTombstones).insert(row);
        }
      });

  /// 同步应用端专用：orderUpdatedAt 镜像成清单里的值（不是 now——同步应用不是
  /// 人为改序，写 now 会让两端时间戳互相追赶、掩盖真正的手动序 LWW）。
  Future<void> setCollectionOrderUpdatedAt(int id, int orderUpdatedAtMs) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
          MediaCollectionsCompanion(orderUpdatedAt: Value(orderUpdatedAtMs)));

  /// 同步应用端专用：按显式 sortIndex upsert 一条成员行（不走尾插、不清墓碑——
  /// 墓碑状态由清单镜像 [replaceCollectionTombstonesFor] 统一处理）。
  Future<void> upsertCollectionItemAt(
          int collectionId, String mediaType, String entryKey, int sortIndex) =>
      into(mediaCollectionItems).insertOnConflictUpdate(
        MediaCollectionItemsCompanion.insert(
          collectionId: collectionId,
          mediaType: mediaType,
          entryKey: entryKey,
          sortIndex: Value(sortIndex),
        ),
      );

  /// 同步应用端专用：删一条成员行（不写墓碑、不触发移空自删——空壳收尾由同步
  /// 应用端按合并后清单统一决定）。
  Future<void> deleteCollectionItemRaw(
          int collectionId, String mediaType, String entryKey) =>
      (delete(mediaCollectionItems)
            ..where((t) =>
                t.collectionId.equals(collectionId) &
                t.mediaType.equals(mediaType) &
                t.entryKey.equals(entryKey)))
          .go();

  /// 同步应用端专用：原样删除合集行 + 其全部成员引用行，**不写任何墓碑**——
  /// 墓碑状态由同步应用端按合并后清单镜像（对比用户路径
  /// [deleteMediaCollection] 会写 now 时间戳的合集级墓碑）。
  Future<void> deleteMediaCollectionRaw(int id) => transaction(() async {
        await (delete(mediaCollectionItems)
              ..where((t) => t.collectionId.equals(id)))
            .go();
        await (delete(mediaCollections)..where((t) => t.id.equals(id))).go();
      });

  // ── audio cues ──────────────────────────────────────────────────
  // [bookKey] is the owner key: either an audiobook bookKey OR an srt_books.uid
  // (SRT books still key their cues on their own uid string).
  Future<List<AudioCueRow>> getCuesForChapter(
          String bookKey, String chapterHref) =>
      (select(audioCues)
            ..where((t) =>
                t.bookKey.equals(bookKey) & t.chapterHref.equals(chapterHref))
            ..orderBy([(t) => OrderingTerm.asc(t.sentenceIndex)]))
          .get();

  Future<List<AudioCueRow>> getCuesForBook(String bookKey) => (select(audioCues)
        ..where((t) => t.bookKey.equals(bookKey))
        ..orderBy([
          (t) => OrderingTerm.asc(t.audioFileIndex),
          (t) => OrderingTerm.asc(t.startMs),
          (t) => OrderingTerm.asc(t.sentenceIndex),
        ]))
      .get();

  Future<AudioCueRow?> findCue(
          String bookKey, String chapterHref, int sentenceIndex) =>
      (select(audioCues)
            ..where((t) =>
                t.bookKey.equals(bookKey) &
                t.chapterHref.equals(chapterHref) &
                t.sentenceIndex.equals(sentenceIndex)))
          .getSingleOrNull();

  Future<void> replaceCuesForBook(
          String bookKey, List<AudioCuesCompanion> cues) =>
      transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookKey))).go();
        await batch((b) {
          for (final c in cues) {
            b.insert(audioCues, c);
          }
        });
      });

  // ── srt books ───────────────────────────────────────────────────
  Future<List<SrtBookRow>> getAllSrtBooks() =>
      (select(srtBooks)..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  /// 监听有声书（SrtBooks）uid 集合，供书架有声书列表在任意导入路径落库后自动
  /// 刷新（同 [watchVideoBookUids]，把书籍从「每个导入点各自记得 invalidate」的
  /// 脆弱模式解放出来，BUG-793）。消费方按集合 `.distinct` 去重，纯列更新不触发。
  Stream<List<String>> watchSrtBookUids() =>
      select(srtBooks).map((SrtBookRow row) => row.uid).watch();

  Future<SrtBookRow?> getSrtBookByUid(String uid) =>
      (select(srtBooks)..where((t) => t.uid.equals(uid))).getSingleOrNull();

  Future<SrtBookRow?> getSrtBookByBookKey(String bookKey) =>
      (select(srtBooks)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  Future<void> upsertSrtBook(SrtBooksCompanion book) =>
      into(srtBooks).insertOnConflictUpdate(book);

  /// Deletes the SRT book row + its cues. Returns the number of srt_books rows
  /// actually removed (0 when [uid] matched no row) so batch deletion can count
  /// only genuine deletions instead of optimistically assuming success
  /// (BUG-439).
  Future<int> deleteSrtBookByUid(String uid) => transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(uid))).go();
        // TODO-616：同事务清 shelf_entry（mediaType='srt'、entryKey=uid）。
        await deleteShelfEntry(MediaKind.srt, uid);
        return (delete(srtBooks)..where((t) => t.uid.equals(uid))).go();
      });

  // ── reader positions ────────────────────────────────────────────
  Future<ReaderPositionRow?> getReaderPosition(String bookKey) =>
      (select(readerPositions)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  /// BUG-777: bulk read for the shelf's "last read at" map (bookKey ->
  /// updatedAt). One query instead of N per-book lookups.
  Future<List<ReaderPositionRow>> getAllReaderPositions() =>
      select(readerPositions).get();

  Future<void> upsertReaderPosition(ReaderPositionsCompanion pos) =>
      into(readerPositions).insert(
        pos,
        onConflict: DoUpdate(
          (old) => pos,
          target: [readerPositions.bookKey],
        ),
      );

  Future<int> deleteReaderPosition(String bookKey) =>
      (delete(readerPositions)..where((t) => t.bookKey.equals(bookKey))).go();

  // ── reading statistics ──────────────────────────────────────────
  /// OVERWRITE semantics: sets the row for (title, dateKey) to the absolute
  /// values in [stat]. Use this when the caller already holds the final total
  /// (e.g. sync merge). For incremental session deltas use
  /// [addReadingStatistic], which accumulates. Passing a delta here would
  /// silently reset the totals.
  /// 绝对值覆盖（同步/备份合并用）。**刻意不写 `pagesRead`**：页数是 v60 新增的本机
  /// 维度，跨设备 wire 契约不带它（[StatBucket] 要求两端字段集一致）。冲突更新只覆盖
  /// 三个老列，本地已记的页数不会被对端的「没有页数」抹成 0。
  Future<void> setReadingStatistic(ReadingStatisticsCompanion stat) =>
      into(readingStatistics).insert(
        stat,
        onConflict: DoUpdate(
          (old) => ReadingStatisticsCompanion(
            charactersRead: stat.charactersRead,
            readingTimeMs: stat.readingTimeMs,
            lastStatisticModified: stat.lastStatisticModified,
          ),
          target: [readingStatistics.title, readingStatistics.dateKey],
        ),
      );

  /// ACCUMULATE semantics: adds [charsRead]/[timeMs] to the existing totals
  /// for (title, dateKey). Use for reading-session deltas. For setting an
  /// absolute total (e.g. sync merge) use [setReadingStatistic].
  /// 累加一条当日阅读统计。[pagesRead] 是 v60 的页数维度（漫画/PDF 传真实翻过的
  /// 页数，EPUB 不传即 0），与 [charsRead] 各自独立累加，互不顶替。
  Future<void> addReadingStatistic({
    required String title,
    required String dateKey,
    required int charsRead,
    required int timeMs,
    int pagesRead = 0,
  }) =>
      transaction(() async {
        final existing = await (select(readingStatistics)
              ..where((t) => t.title.equals(title) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(readingStatistics)
                ..where((t) => t.id.equals(existing.id)))
              .write(ReadingStatisticsCompanion(
            charactersRead: Value(existing.charactersRead + charsRead),
            readingTimeMs: Value(existing.readingTimeMs + timeMs),
            pagesRead: Value(existing.pagesRead + pagesRead),
            lastStatisticModified: Value(DateTime.now().millisecondsSinceEpoch),
          ));
        } else {
          await into(readingStatistics).insert(
            ReadingStatisticsCompanion.insert(
              title: title,
              dateKey: dateKey,
              charactersRead: charsRead,
              readingTimeMs: timeMs,
              pagesRead: Value(pagesRead),
              lastStatisticModified: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          // 首次为该书当日建统计行 = 用户重新读它：清其统计删除墓碑（若有），让
          // 该书统计重新参与云同步 / 备份合并（TODO-1204 后续）。
          await clearStatisticsTombstone(title, statSourceBook);
        }
      });

  Future<List<ReadingStatisticRow>> getAllReadingStatistics() =>
      select(readingStatistics).get();

  // ── reading hourly logs ─────────────────────────────────────────
  /// ACCUMULATE：把 [deltaMs] 累加进 (dateKey, hour, format) 桶。[format] 是写入
  /// 面身份（EPUB / PDF / 漫画阅读器各报各的），v67 起时段数据按它可拆。
  Future<void> addHourlyReadingTime({
    required String dateKey,
    required int hour,
    required int deltaMs,
    required BookFormat format,
  }) =>
      _addHourlyReadingTimeRaw(
        dateKey: dateKey,
        hour: hour,
        deltaMs: deltaMs,
        format: format.dbValue,
      );

  /// 云聚合同步专用：把旧端（不带 format 的 wire 快照）贡献的、无法归因到任何
  /// 写入面的逐时差额累加进 `''`（未区分）桶。普通写入面一律走带 [BookFormat]
  /// 的 [addHourlyReadingTime]，不得用本方法制造新的未区分数据。
  Future<void> addUnattributedHourlyReadingTime({
    required String dateKey,
    required int hour,
    required int deltaMs,
  }) =>
      _addHourlyReadingTimeRaw(
        dateKey: dateKey,
        hour: hour,
        deltaMs: deltaMs,
        format: '',
      );

  Future<void> _addHourlyReadingTimeRaw({
    required String dateKey,
    required int hour,
    required int deltaMs,
    required String format,
  }) =>
      transaction(() async {
        final existing = await (select(readingHourlyLogs)
              ..where((t) =>
                  t.dateKey.equals(dateKey) &
                  t.hour.equals(hour) &
                  t.format.equals(format)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(readingHourlyLogs)
                ..where((t) => t.id.equals(existing.id)))
              .write(ReadingHourlyLogsCompanion(
            readingTimeMs: Value(existing.readingTimeMs + deltaMs),
          ));
        } else {
          await into(readingHourlyLogs).insert(
            ReadingHourlyLogsCompanion.insert(
              dateKey: dateKey,
              hour: hour,
              readingTimeMs: deltaMs,
              format: Value(format),
            ),
          );
        }
      });

  Future<List<ReadingHourlyLogRow>> getHourlyLogsForDate(String dateKey) =>
      (select(readingHourlyLogs)..where((t) => t.dateKey.equals(dateKey)))
          .get();

  /// 逐行读取全部阅读小时日志，供云聚合同步 materialize 快照（TODO-1056 phase B）。
  Future<List<ReadingHourlyLogRow>> getAllReadingHourlyLogs() =>
      select(readingHourlyLogs).get();

  /// OVERWRITE 语义：把 (dateKey, hour, format) 桶设为绝对值 [readingTimeMs]。
  /// 云聚合合并已在 Dart 侧算好 MAX，这里直接落绝对值（对照
  /// [addHourlyReadingTime] 的累加）。[format] 收裸串而非 [BookFormat]：wire 快照
  /// 可能来自带未来新格式值的新版本端，本方法逐字节保存、不得折叠成已知枚举。
  Future<void> setReadingHourlyLog({
    required String dateKey,
    required int hour,
    required int readingTimeMs,
    required String format,
  }) =>
      into(readingHourlyLogs).insert(
        ReadingHourlyLogsCompanion.insert(
          dateKey: dateKey,
          hour: hour,
          readingTimeMs: readingTimeMs,
          format: Value(format),
        ),
        onConflict: DoUpdate(
          (_) =>
              ReadingHourlyLogsCompanion(readingTimeMs: Value(readingTimeMs)),
          target: [
            readingHourlyLogs.dateKey,
            readingHourlyLogs.hour,
            readingHourlyLogs.format,
          ],
        ),
      );

  // ── video watch statistics ──────────────────────────────────────
  /// ACCUMULATE：把 [subtitleChars]/[watchTimeMs] 累加到 (title, dateKey) 现有
  /// 总量。对照 [addReadingStatistic]，但视频专用、与阅读统计隔离。
  Future<void> addVideoWatchStatistic({
    required String title,
    required String dateKey,
    required int subtitleChars,
    required int watchTimeMs,
    String? bookUid,
  }) =>
      transaction(() async {
        // v39：有 bookUid（当前所有真实写入方）按 (bookUid,dateKey) 键控，同名
        // 不同视频各自累计；无 bookUid（兼容旧调用）按旧 (title,dateKey) 且只命中
        // 遗留 NULL-uid 行，不污染新键控行。
        final existing = await (select(videoWatchStatistics)
              ..where((t) => bookUid != null
                  ? (t.bookUid.equals(bookUid) & t.dateKey.equals(dateKey))
                  : (t.title.equals(title) &
                      t.dateKey.equals(dateKey) &
                      t.bookUid.isNull())))
            .getSingleOrNull();
        if (existing != null) {
          await (update(videoWatchStatistics)
                ..where((t) => t.id.equals(existing.id)))
              .write(VideoWatchStatisticsCompanion(
            subtitleChars: Value(existing.subtitleChars + subtitleChars),
            watchTimeMs: Value(existing.watchTimeMs + watchTimeMs),
            lastModified: Value(DateTime.now().millisecondsSinceEpoch),
          ));
        } else {
          await into(videoWatchStatistics).insert(
            VideoWatchStatisticsCompanion.insert(
              bookUid: Value(bookUid),
              title: title,
              dateKey: dateKey,
              subtitleChars: subtitleChars,
              watchTimeMs: watchTimeMs,
              lastModified: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          // 重新观看该视频：清其统计删除墓碑（TODO-1204 后续）。
          await clearStatisticsTombstone(title, statSourceVideo);
        }
      });

  Future<List<VideoWatchStatisticRow>> getAllVideoWatchStatistics() =>
      select(videoWatchStatistics).get();

  // ── activity events (v49) ───────────────────────────────────────
  /// 追加一条活动事件（每次阅读/观看 session 结束或导入完成时写一行）。纯追加，
  /// 不去重、不累加——同书同日多次 session = 多行，读取端按需分组/计数。
  Future<void> addActivityEvent({
    required String eventType,
    required String mediaType,
    required String title,
    required String dateKey,
    required int timestampMs,
    String? mediaKey,
    int? durationMs,
    int? charsDelta,
  }) =>
      into(activityEvents).insert(
        ActivityEventsCompanion.insert(
          eventType: eventType,
          mediaType: mediaType,
          title: title,
          dateKey: dateKey,
          timestampMs: timestampMs,
          mediaKey: Value(mediaKey),
          durationMs: Value(durationMs),
          charsDelta: Value(charsDelta),
        ),
      );

  /// 取最近 [limit] 条活动事件，按精确时刻倒序（首页 Activity 面板消费）。
  /// [eventTypes] 非空时只取这些类别（如只看 'read'），null = 全部类别。
  Future<List<ActivityEventRow>> getRecentActivityEvents({
    int limit = 200,
    List<String>? eventTypes,
  }) {
    final SimpleSelectStatement<$ActivityEventsTable, ActivityEventRow> query =
        select(activityEvents)
          ..orderBy([
            (t) => OrderingTerm(
                  expression: t.timestampMs,
                  mode: OrderingMode.desc,
                ),
          ])
          ..limit(limit);
    if (eventTypes != null && eventTypes.isNotEmpty) {
      query.where((t) => t.eventType.isIn(eventTypes));
    }
    return query.get();
  }

  /// 按 date_key 聚合某类活动（首页热力图/趋势按天消费）：返回每天的字符增量与
  /// 时长合计，`chars_delta` / `duration_ms` 为 null 记 0。在 SQL 侧先聚合，避免把
  /// 整表活动行拉进内存再分组。
  Future<List<(String dateKey, int charsDelta, int durationMs)>>
      getActivityDailyTotals(String eventType) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT date_key, '
      'COALESCE(SUM(chars_delta), 0) AS chars_total, '
      'COALESCE(SUM(duration_ms), 0) AS duration_total '
      'FROM activity_events WHERE event_type = ? GROUP BY date_key',
      variables: [Variable.withString(eventType)],
    ).get();
    return [
      for (final QueryRow row in rows)
        (
          row.read<String>('date_key'),
          row.read<int>('chars_total'),
          row.read<int>('duration_total'),
        ),
    ];
  }

  /// 某日某类活动按 title 聚合（首页某天详情消费）：返回每个标题的字符/时长合计，
  /// 按时长（duration_ms 合计）降序。null 记 0。
  Future<List<(String title, int charsDelta, int durationMs)>>
      getActivityTitleTotalsForDay(String eventType, String dateKey) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT title, '
      'COALESCE(SUM(chars_delta), 0) AS chars_total, '
      'COALESCE(SUM(duration_ms), 0) AS duration_total '
      'FROM activity_events WHERE event_type = ? AND date_key = ? '
      'GROUP BY title ORDER BY duration_total DESC',
      variables: [
        Variable.withString(eventType),
        Variable.withString(dateKey),
      ],
    ).get();
    return [
      for (final QueryRow row in rows)
        (
          row.read<String>('title'),
          row.read<int>('chars_total'),
          row.read<int>('duration_total'),
        ),
    ];
  }

  /// 删除某标题的全部活动事件（书/视频被删除时清理，对齐统计表清理路径）。
  Future<int> deleteActivityEventsForTitle(String title) =>
      (delete(activityEvents)..where((t) => t.title.equals(title))).go();

  /// 清空全部活动事件（统计「清除全部」路径联动）。
  Future<int> clearAllActivityEvents() => delete(activityEvents).go();

  // ── galgames / galgame_sources / galgame_sessions (v55 游戏库) ──────
  //
  // 设计见 `docs/design/galgame-library-reina-parity.md`。这里刻意没有统计投影表：
  // 时长/次数/最后游玩全部现算 GROUP BY（见下面聚合方法），一次消掉「投影与
  // 事实表不一致」的整类 bug。单机规模是几百游戏 × 几千会话，SQLite 毫秒级。

  /// 全部游戏，按添加时间升序（与旧 JSON 列表的天然顺序一致，Never break userspace）。
  Future<List<GalgameRow>> getAllGalgames() =>
      (select(galgames)..orderBy([(t) => OrderingTerm.asc(t.addedAt)])).get();

  /// 监听全部游戏（库页实时刷新）。
  Stream<List<GalgameRow>> watchAllGalgames() =>
      (select(galgames)..orderBy([(t) => OrderingTerm.asc(t.addedAt)])).watch();

  Future<GalgameRow?> getGalgame(String id) =>
      (select(galgames)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 新增或整行覆盖一条游戏。
  Future<void> upsertGalgame(GalgamesCompanion entry) =>
      into(galgames).insertOnConflictUpdate(entry);

  /// 删除一条游戏。`galgame_sources` / `galgame_sessions` 经 FK cascade 连带清理。
  Future<int> deleteGalgame(String id) =>
      (delete(galgames)..where((t) => t.id.equals(id))).go();

  /// 只改游玩状态（0=未设置 / 1=想玩 / 2=玩过 / 3=在玩 / 4=搁置 / 5=弃坑）。
  Future<int> setGalgamePlayStatus(String id, int status) =>
      (update(galgames)..where((t) => t.id.equals(id)))
          .write(GalgamesCompanion(playStatus: Value<int>(status)));

  /// 只改用户覆盖层 JSON（null = 清空全部自定义，展示回落到刮削值/本地默认名）。
  Future<int> setGalgameCustomData(String id, String? json) =>
      (update(galgames)..where((t) => t.id.equals(id)))
          .write(GalgamesCompanion(customDataJson: Value<String?>(json)));

  /// 只改本地封面路径（null = 回落默认手柄图标）。
  Future<int> setGalgameCoverPath(String id, String? path) =>
      (update(galgames)..where((t) => t.id.equals(id)))
          .write(GalgamesCompanion(coverPath: Value<String?>(path)));

  /// 只改该游戏的窗口超分档位（'auto' / 'installed_only' / 'off'；空串 = 未设置，
  /// 解析层回落到关闭）。列非空，所以清空是写空串而不是写 null。
  Future<int> setGalgameUpscalingMode(String id, String modeKey) =>
      (update(galgames)..where((t) => t.id.equals(id)))
          .write(GalgamesCompanion(upscalingMode: Value<String>(modeKey)));

  /// 刮削成功后回写主显示源与发行日（发行日上提成列是为了 SQL 排序）。
  Future<int> setGalgameScrapeResult(
    String id, {
    required String? primarySource,
    required String? releaseDate,
  }) =>
      (update(galgames)..where((t) => t.id.equals(id))).write(
        GalgamesCompanion(
          primarySource: Value<String?>(primarySource),
          releaseDate: Value<String?>(releaseDate),
        ),
      );

  /// 某游戏的全部元数据源快照。
  Future<List<GalgameSourceRow>> getGalgameSources(String gameId) =>
      (select(galgameSources)..where((t) => t.gameId.equals(gameId))).get();

  /// 全库元数据源快照，按 gameId 分组（库页一次取全量，避免 N+1）。
  Future<Map<String, List<GalgameSourceRow>>> getAllGalgameSources() async {
    final List<GalgameSourceRow> rows = await select(galgameSources).get();
    final Map<String, List<GalgameSourceRow>> out =
        <String, List<GalgameSourceRow>>{};
    for (final GalgameSourceRow row in rows) {
      (out[row.gameId] ??= <GalgameSourceRow>[]).add(row);
    }
    return out;
  }

  /// 写入/刷新一个源的快照（同 `(gameId, source)` 覆盖）。
  Future<void> upsertGalgameSource(GalgameSourcesCompanion entry) =>
      into(galgameSources).insertOnConflictUpdate(entry);

  /// 移除某游戏的某个源（「换数据源」时清掉旧源）。
  Future<int> deleteGalgameSource(String gameId, String source) =>
      (delete(galgameSources)
            ..where((t) => t.gameId.equals(gameId) & t.source.equals(source)))
          .go();

  /// 落一条游玩会话。返回自增 id。
  Future<int> insertGalgameSession(GalgameSessionsCompanion entry) =>
      into(galgameSessions).insert(entry);

  /// 某游戏的会话流水，按起始时间倒序（详情页时间线，支持分页）。
  Future<List<GalgameSessionRow>> getGalgameSessions(
    String gameId, {
    int limit = 50,
    int offset = 0,
  }) =>
      (select(galgameSessions)
            ..where((t) => t.gameId.equals(gameId))
            ..orderBy([(t) => OrderingTerm.desc(t.startMs)])
            ..limit(limit, offset: offset))
          .get();

  /// 删除单条会话（详情页「删掉这次记录」）。
  Future<int> deleteGalgameSession(int id) =>
      (delete(galgameSessions)..where((t) => t.id.equals(id))).go();

  /// 清空游戏统计，只删除游玩会话事实。
  ///
  /// 游戏库（[galgames]）与首页活动时间线（[activityEvents]）是独立用户数据，
  /// 不能因统计页的「清空」操作被连带删除。
  Future<int> clearAllGalgameStatistics() => delete(galgameSessions).go();

  /// 全库每个游戏的时长合计（秒）+ 会话次数 + 最后游玩毫秒戳。
  ///
  /// 库页排序（按总时长 / 按最后游玩）与详情页 KPI 都吃这一个查询，取代上游的
  /// `game_statistics` 投影表。
  Future<Map<String, (int totalSeconds, int sessionCount, int lastPlayedMs)>>
      getGalgamePlayTotals() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT game_id, '
      'COALESCE(SUM(duration_seconds), 0) AS total_seconds, '
      'COUNT(*) AS session_count, '
      'COALESCE(MAX(end_ms), 0) AS last_played_ms '
      'FROM galgame_sessions GROUP BY game_id',
      readsFrom: {galgameSessions},
    ).get();
    return <String, (int, int, int)>{
      for (final QueryRow row in rows)
        row.read<String>('game_id'): (
          row.read<int>('total_seconds'),
          row.read<int>('session_count'),
          row.read<int>('last_played_ms'),
        ),
    };
  }

  /// 某游戏按天的时长合计（秒），供详情页每日柱状图。
  /// [fromDateKey] / [toDateKey] 是闭区间的 'YYYY-MM-DD'（字典序即时间序）。
  Future<Map<String, int>> getGalgameDailySeconds(
    String gameId, {
    required String fromDateKey,
    required String toDateKey,
  }) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT date_key, COALESCE(SUM(duration_seconds), 0) AS total_seconds '
      'FROM galgame_sessions '
      'WHERE game_id = ? AND date_key >= ? AND date_key <= ? '
      'GROUP BY date_key',
      variables: [
        Variable.withString(gameId),
        Variable.withString(fromDateKey),
        Variable.withString(toDateKey),
      ],
      readsFrom: {galgameSessions},
    ).get();
    return <String, int>{
      for (final QueryRow row in rows)
        row.read<String>('date_key'): row.read<int>('total_seconds'),
    };
  }

  /// 全部游戏按天的游玩时长（秒）与会话数。
  ///
  /// 游戏统计页与首页汇总只认 [galgameSessions] 事实表；`activity_events` 是时间线，
  /// 不能反过来充当时长统计投影。返回全部历史日期，读取端按今日/周/月窗口筛选。
  Future<Map<String, (int totalSeconds, int sessionCount)>>
      getAllGalgameDailyTotals() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT date_key, '
      'COALESCE(SUM(duration_seconds), 0) AS total_seconds, '
      'COUNT(*) AS session_count '
      'FROM galgame_sessions GROUP BY date_key',
      readsFrom: {galgameSessions},
    ).get();
    return <String, (int, int)>{
      for (final QueryRow row in rows)
        row.read<String>('date_key'): (
          row.read<int>('total_seconds'),
          row.read<int>('session_count'),
        ),
    };
  }

  /// 某天全部游戏的时长合计（秒），供首页「今日游戏时长」。
  Future<int> getGalgameSecondsForDay(String dateKey) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT COALESCE(SUM(duration_seconds), 0) AS total_seconds '
      'FROM galgame_sessions WHERE date_key = ?',
      variables: [Variable.withString(dateKey)],
      readsFrom: {galgameSessions},
    ).get();
    return rows.isEmpty ? 0 : rows.first.read<int>('total_seconds');
  }

  /// 首页仪表盘的「数据变了」信号：activity_events / reading_statistics /
  /// video_watch_statistics / video_books 任一表变更即 emit（不带数据，消费方自行
  /// 重查聚合）。首页据此在阅读/观看/导入落库后**自动刷新**热力图 + 时长 + 活动
  /// 时间轴——否则首页在 pushed 阅读器路由下不重建，读完回来仍是旧数据（用户报
  /// 「打开一本书 Activity 还是空的」）。
  ///
  /// 用手动 [StreamController] + [tableUpdates]，**不用** drift keyed `.watch()`：
  /// 后者取消订阅会遗留缓存保留 `Timer.run`，触发 flutter_test `!timersPending`
  /// 让 flutter_tester 永不退出（BUG-834，见 [watchVideoBookUids] 详注）。
  /// tableUpdates 流取消时不安排该 Timer，widget 测试可正常收敛。
  Stream<void> watchDashboardDataChanges() {
    late final StreamController<void> controller;
    StreamSubscription<void>? updatesSub;
    controller = StreamController<void>(
      onListen: () {
        updatesSub = tableUpdates(
          TableUpdateQuery
              .onAllTables(<ResultSetImplementation<dynamic, dynamic>>[
            activityEvents,
            readingStatistics,
            videoWatchStatistics,
            videoBooks,
          ]),
        ).listen((_) {
          if (!controller.isClosed) controller.add(null);
        });
      },
      onCancel: () async {
        await updatesSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// OVERWRITE 语义：把 (title, dateKey) 桶设为绝对值（对照 [setReadingStatistic]，
  /// 供云聚合合并写回；[addVideoWatchStatistic] 是累加，云合并禁用会重复计数）。
  Future<void> setVideoWatchStatistic(VideoWatchStatisticsCompanion stat) =>
      transaction(() async {
        // v39：本地行按 bookUid 键控，但互通聚合线协议仍是 title 粒度。OVERWRITE
        // 语义改为「删该 (title,dateKey) 全部行（含 per-uid 行）→ 写单一 NULL-uid
        // 权威行」——沿用旧“每 (title,date) 一行”语义、避免与 per-uid 行叠加双计；
        // 代价是启用互通统计同步的库该日行退化回 title 粒度（协议升级 per-uid 前
        // 的已知限制，见 UI v2 计划文档）。
        await (delete(videoWatchStatistics)
              ..where((t) =>
                  t.title.equals(stat.title.value) &
                  t.dateKey.equals(stat.dateKey.value)))
            .go();
        await into(videoWatchStatistics).insert(stat);
      });

  // ── video hourly logs ───────────────────────────────────────────
  Future<void> addVideoHourlyWatchTime({
    required String dateKey,
    required int hour,
    required int deltaMs,
  }) =>
      transaction(() async {
        final existing = await (select(videoHourlyLogs)
              ..where((t) => t.dateKey.equals(dateKey) & t.hour.equals(hour)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(videoHourlyLogs)
                ..where((t) => t.id.equals(existing.id)))
              .write(VideoHourlyLogsCompanion(
            watchTimeMs: Value(existing.watchTimeMs + deltaMs),
          ));
        } else {
          await into(videoHourlyLogs).insert(
            VideoHourlyLogsCompanion.insert(
              dateKey: dateKey,
              hour: hour,
              watchTimeMs: deltaMs,
            ),
          );
        }
      });

  Future<List<VideoHourlyLogRow>> getVideoHourlyLogsForDate(String dateKey) =>
      (select(videoHourlyLogs)..where((t) => t.dateKey.equals(dateKey))).get();

  /// 逐行读取全部视频小时日志，供云聚合同步 materialize 快照（TODO-1056 phase B）。
  Future<List<VideoHourlyLogRow>> getAllVideoHourlyLogs() =>
      select(videoHourlyLogs).get();

  /// OVERWRITE 语义：把 (dateKey, hour) 桶设为绝对值 [watchTimeMs]（对照
  /// [addVideoHourlyWatchTime] 的累加）。云聚合合并已在 Dart 侧算好 MAX。
  Future<void> setVideoHourlyLog({
    required String dateKey,
    required int hour,
    required int watchTimeMs,
  }) =>
      into(videoHourlyLogs).insert(
        VideoHourlyLogsCompanion.insert(
          dateKey: dateKey,
          hour: hour,
          watchTimeMs: watchTimeMs,
        ),
        onConflict: DoUpdate(
          (_) => VideoHourlyLogsCompanion(watchTimeMs: Value(watchTimeMs)),
          target: [videoHourlyLogs.dateKey, videoHourlyLogs.hour],
        ),
      );

  /// 仅当当前 completed_at 为 null 时写入（幂等首次完成；重看不覆盖）。
  Future<void> markVideoCompleted(String bookUid, DateTime completedAt) =>
      (update(videoBooks)
            ..where((t) => t.bookUid.equals(bookUid) & t.completedAt.isNull()))
          .write(VideoBooksCompanion(completedAt: Value(completedAt)));

  // ── favorite words ──────────────────────────────────────────────
  /// 收藏一个词条（幂等：(expression, reading, sourceType) 已存在则跳过）。
  /// 返回 true 表示这次新增了收藏，false 表示已收藏过。
  Future<bool> addFavoriteWord({
    required String expression,
    required String reading,
    required String glossary,
    required String sourceType,
    required String dateKey,
    String? bookKey,
    String title = '',
  }) =>
      transaction(() async {
        final existing = await (select(favoriteWords)
              ..where((t) =>
                  t.expression.equals(expression) &
                  t.reading.equals(reading) &
                  t.sourceType.equals(sourceType)))
            .getSingleOrNull();
        if (existing != null) return false;
        // 删除传播：重新收藏同 (expression,reading,sourceType) → 清其 sync 删除墓碑，
        // 防「取消了又收藏、墓碑还在」被 aggregate 抑制或跨端误删（范式仿插书清碑）。
        await clearSyncDeletionTombstone(SyncTombstoneKind.favoriteword.dbValue,
            favoriteWordItemKey(expression, reading, sourceType));
        // TODO-1252：[bookKey] / [title] 记「首次收藏归属书」——收藏时若在阅读器 / 视频
        // 页有书上下文则传入，供 per-book/video tile 聚合；无书来源保持 null / ''（只进
        // 汇总）。uniqueKey 仍 {expression, reading, sourceType} 全局去重，归属标签是新增
        // 旁路信息，不改去重 / 汇总 / 同步语义。
        await into(favoriteWords).insert(
          FavoriteWordsCompanion.insert(
            expression: expression,
            reading: Value(reading),
            glossary: Value(glossary),
            sourceType: sourceType,
            bookKey: Value(bookKey),
            title: Value(title),
            dateKey: dateKey,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        return true;
      });

  /// 取消收藏（按 (expression, reading, sourceType) 删除）。返回删除的行数。
  ///
  /// [propagateDeletion]（默认 true）：收藏是跨设备 aggregate 并集同步的集合，取消收藏
  /// 若不记墓碑，下次同步会被 peer 快照并回（复活）。故默认写一条 `favoriteword` sync
  /// 删除墓碑——既供 aggregate 消费端抑制并集复活（[AggregateSyncService.applySnapshotToLocal]
  /// 跳过有墓碑的收藏），也发布到远端标记让其他设备逐条确认后也删。消费端删除时传 false 亦可
  /// （幂等：墓碑已存在），此处保留参数以备内部非用户删除路径按需关闭。
  Future<int> removeFavoriteWord({
    required String expression,
    required String reading,
    required String sourceType,
    bool propagateDeletion = true,
  }) async {
    final int removed = await (delete(favoriteWords)
          ..where((t) =>
              t.expression.equals(expression) &
              t.reading.equals(reading) &
              t.sourceType.equals(sourceType)))
        .go();
    if (removed > 0 && propagateDeletion) {
      await writeSyncDeletionTombstone(
          SyncTombstoneKind.favoriteword.dbValue,
          favoriteWordItemKey(expression, reading, sourceType),
          DateTime.now().millisecondsSinceEpoch);
    }
    return removed;
  }

  /// 收藏词跨设备稳定身份键（= uniqueKey {expression, reading, sourceType} 的 NUL 连接串），
  /// 用作 `favoriteword` sync 删除墓碑的 itemKey。NUL 分隔符文本几乎不可能出现（同项目
  /// NUL 分组键约定），可逆解析见 app 层 `parseFavoriteWordItemKey`。
  static String favoriteWordItemKey(
          String expression, String reading, String sourceType) =>
      '$expression\u0000$reading\u0000$sourceType';

  Future<bool> isFavoriteWord({
    required String expression,
    required String reading,
    required String sourceType,
  }) async {
    final row = await (select(favoriteWords)
          ..where((t) =>
              t.expression.equals(expression) &
              t.reading.equals(reading) &
              t.sourceType.equals(sourceType)))
        .getSingleOrNull();
    return row != null;
  }

  /// 取某来源（'book' / 'video'）的全部收藏行，供统计页按 dateKey 分桶计数。
  Future<List<FavoriteWordRow>> getFavoriteWordsBySource(String sourceType) =>
      (select(favoriteWords)..where((t) => t.sourceType.equals(sourceType)))
          .get();

  /// 取全部收藏词，按 createdAt 倒序（最近在前），供收藏夹导出（TODO-829）。
  /// 纯 select，不动 schema。
  Future<List<FavoriteWordRow>> getAllFavoriteWords() =>
      (select(favoriteWords)..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  // ── mining statistics ───────────────────────────────────────────
  /// 制卡成功计数 +[delta]：累加到 (sourceType, dateKey) 现有计数。
  Future<void> addMiningCount({
    required String sourceType,
    required String dateKey,
    int delta = 1,
  }) =>
      transaction(() async {
        final existing = await (select(miningStatistics)
              ..where((t) =>
                  t.sourceType.equals(sourceType) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(miningStatistics)
                ..where((t) => t.id.equals(existing.id)))
              .write(MiningStatisticsCompanion(
            count: Value(existing.count + delta),
          ));
        } else {
          await into(miningStatistics).insert(
            MiningStatisticsCompanion.insert(
              sourceType: sourceType,
              dateKey: dateKey,
              count: Value(delta),
            ),
          );
        }
      });

  /// MAX-union semantics: sets the (sourceType, dateKey) bucket to
  /// `max(existing, count)` rather than accumulating. Use this for backup-merge
  /// import — accumulating with [addMiningCount] would double-count on a
  /// re-import of the same backup, breaking the "merge is idempotent" invariant
  /// (mirrors [setReadingStatistic]'s absolute / `mergeStatistics` max
  /// semantics).
  Future<void> setMiningCount({
    required String sourceType,
    required String dateKey,
    required int count,
  }) =>
      transaction(() async {
        final existing = await (select(miningStatistics)
              ..where((t) =>
                  t.sourceType.equals(sourceType) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          if (count > existing.count) {
            await (update(miningStatistics)
                  ..where((t) => t.id.equals(existing.id)))
                .write(MiningStatisticsCompanion(count: Value(count)));
          }
        } else {
          await into(miningStatistics).insert(
            MiningStatisticsCompanion.insert(
              sourceType: sourceType,
              dateKey: dateKey,
              count: Value(count),
            ),
          );
        }
      });

  /// 取某来源（'book' / 'video'）的全部制卡计数行，供统计页按 dateKey 分桶。
  Future<List<MiningStatisticRow>> getMiningStatisticsBySource(
          String sourceType) =>
      (select(miningStatistics)..where((t) => t.sourceType.equals(sourceType)))
          .get();

  /// 逐行读取全部制卡计数行（所有来源），供云聚合同步 materialize 快照
  /// （TODO-1056 phase B）。写回用 [setMiningCount]（MAX 语义、幂等）。
  Future<List<MiningStatisticRow>> getAllMiningStatistics() =>
      select(miningStatistics).get();

  // ── lookup / mining per-book counters (TODO-1204) ────────────────
  /// 查词计数 +[delta]：累加到 (title, sourceType, dateKey) 现有行的 [lookupCount]。
  /// 无书查词（首页 / 独立窗 / 歌词）传 [bookKey] = null、[title] = ''（只进全局汇总）。
  /// [bookKey] 仅首次 insert 时落库（供将来同步 / 展示书身份），后续累加不覆盖。
  Future<void> addLookupCount({
    String? bookKey,
    String title = '',
    required String sourceType,
    required String dateKey,
    int delta = 1,
  }) =>
      transaction(() async {
        final existing = await (select(lookupMiningCounters)
              ..where((t) =>
                  t.title.equals(title) &
                  t.sourceType.equals(sourceType) &
                  t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(lookupMiningCounters)
                ..where((t) => t.id.equals(existing.id)))
              .write(LookupMiningCountersCompanion(
            lookupCount: Value(existing.lookupCount + delta),
          ));
        } else {
          await into(lookupMiningCounters).insert(
            LookupMiningCountersCompanion.insert(
              bookKey: Value(bookKey),
              title: Value(title),
              sourceType: sourceType,
              dateKey: dateKey,
              lookupCount: Value(delta),
            ),
          );
          // 重新查该书/视频的词 = 新活动：清其统计删除墓碑（无书查词 title='' 不立碑
          // 也无碑可清，跳过；TODO-1204 后续）。
          if (title.isNotEmpty) {
            await clearStatisticsTombstone(title, sourceType);
          }
        }
      });

  /// 制卡计数 +[delta]（per-book）：累加到 (title, sourceType, dateKey) 现有行的
  /// [mineCount]。与全局 [addMiningCount] **并行**写（后者不动），只算成功制卡。
  Future<void> addMineCountPerBook({
    String? bookKey,
    String title = '',
    required String sourceType,
    required String dateKey,
    int delta = 1,
  }) =>
      transaction(() async {
        final existing = await (select(lookupMiningCounters)
              ..where((t) =>
                  t.title.equals(title) &
                  t.sourceType.equals(sourceType) &
                  t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(lookupMiningCounters)
                ..where((t) => t.id.equals(existing.id)))
              .write(LookupMiningCountersCompanion(
            mineCount: Value(existing.mineCount + delta),
          ));
        } else {
          await into(lookupMiningCounters).insert(
            LookupMiningCountersCompanion.insert(
              bookKey: Value(bookKey),
              title: Value(title),
              sourceType: sourceType,
              dateKey: dateKey,
              mineCount: Value(delta),
            ),
          );
          // 重新在该书/视频制卡 = 新活动：清其统计删除墓碑（TODO-1204 后续）。
          if (title.isNotEmpty) {
            await clearStatisticsTombstone(title, sourceType);
          }
        }
      });

  /// MAX-union 语义（非累加）：把 (title, sourceType, dateKey) 行的 [lookupCount]
  /// 设为 `max(existing, count)`。为将来备份合并 / 云聚合幂等重导留口（本期 sync
  /// 不接；与 [setMiningCount] 同范式）。
  Future<void> setLookupCount({
    String? bookKey,
    String title = '',
    required String sourceType,
    required String dateKey,
    required int count,
  }) =>
      transaction(() async {
        final existing = await (select(lookupMiningCounters)
              ..where((t) =>
                  t.title.equals(title) &
                  t.sourceType.equals(sourceType) &
                  t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          if (count > existing.lookupCount) {
            await (update(lookupMiningCounters)
                  ..where((t) => t.id.equals(existing.id)))
                .write(
                    LookupMiningCountersCompanion(lookupCount: Value(count)));
          }
        } else {
          await into(lookupMiningCounters).insert(
            LookupMiningCountersCompanion.insert(
              bookKey: Value(bookKey),
              title: Value(title),
              sourceType: sourceType,
              dateKey: dateKey,
              lookupCount: Value(count),
            ),
          );
        }
      });

  /// MAX-union 语义（非累加）：把 (title, sourceType, dateKey) 行的 [mineCount]
  /// 设为 `max(existing, count)`。备份合并 / 云聚合幂等留口（本期 sync 不接）。
  Future<void> setMineCountPerBook({
    String? bookKey,
    String title = '',
    required String sourceType,
    required String dateKey,
    required int count,
  }) =>
      transaction(() async {
        final existing = await (select(lookupMiningCounters)
              ..where((t) =>
                  t.title.equals(title) &
                  t.sourceType.equals(sourceType) &
                  t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          if (count > existing.mineCount) {
            await (update(lookupMiningCounters)
                  ..where((t) => t.id.equals(existing.id)))
                .write(LookupMiningCountersCompanion(mineCount: Value(count)));
          }
        } else {
          await into(lookupMiningCounters).insert(
            LookupMiningCountersCompanion.insert(
              bookKey: Value(bookKey),
              title: Value(title),
              sourceType: sourceType,
              dateKey: dateKey,
              mineCount: Value(count),
            ),
          );
        }
      });

  /// 取某来源（'book' / 'video'）的全部查词/制卡计数行，供统计页汇总 + per-book
  /// tile 按 title 聚合。
  Future<List<LookupMiningCounterRow>> getLookupMiningCountersBySource(
          String sourceType) =>
      (select(lookupMiningCounters)
            ..where((t) => t.sourceType.equals(sourceType)))
          .get();

  /// 逐行读取全部查词/制卡计数行（所有来源），供将来云聚合同步 materialize 快照。
  /// 写回用 [setLookupCount] / [setMineCountPerBook]（MAX 语义、幂等）。
  Future<List<LookupMiningCounterRow>> getAllLookupMiningCounters() =>
      select(lookupMiningCounters).get();

  // ── mined sentences ──────────────────────────────────────────────
  /// 上限：保留最近 [kMinedSentenceHistoryLimit] 条制卡历史，避免无限增长。
  static const int kMinedSentenceHistoryLimit = 1000;

  /// 记录一次成功制卡：插入一条历史，并在事务内 trim 掉超额的最旧行。
  /// 定位列（[bookKey]/[sectionIndex]/[normCharOffset]/[normCharLength]）按来源可空——
  /// 独立查词页 / 首页词典制卡无书无章，传 null（展示为不可跳转条目）。
  Future<void> addMinedSentence({
    required String source,
    required String dateKey,
    String expression = '',
    String reading = '',
    String glossary = '',
    String sentence = '',
    String? documentTitle,
    String? chapterLabel,
    String? bookKey,
    int? sectionIndex,
    int? normCharOffset,
    int? normCharLength,
    int? noteId,
  }) =>
      transaction(() async {
        await into(minedSentences).insert(
          MinedSentencesCompanion.insert(
            source: source,
            dateKey: dateKey,
            expression: Value(expression),
            reading: Value(reading),
            glossary: Value(glossary),
            sentence: Value(sentence),
            documentTitle: Value(documentTitle),
            chapterLabel: Value(chapterLabel),
            bookKey: Value(bookKey),
            sectionIndex: Value(sectionIndex),
            normCharOffset: Value(normCharOffset),
            normCharLength: Value(normCharLength),
            noteId: Value(noteId),
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await _trimMinedSentences();
      });

  /// 取全部制卡历史，按 createdAt 倒序（最近在前），供收藏夹页展示。
  Future<List<MinedSentenceRow>> getAllMinedSentences() =>
      (select(minedSentences)..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  /// 删除一条制卡历史（按 id）。返回删除的行数。
  Future<int> removeMinedSentence(int id) =>
      (delete(minedSentences)..where((t) => t.id.equals(id))).go();

  /// 清空全部制卡历史。返回删除的行数。
  Future<int> clearMinedSentences() => delete(minedSentences).go();

  /// 清空全部收藏词（FavoriteWords 表）。返回删除的行数。收藏夹「清空」面板的
  /// 收藏词范围走这里，与 [clearMinedSentences] 对称，仅删本表不触碰其它收藏。
  Future<int> clearAllFavoriteWords() => delete(favoriteWords).go();

  /// 事务内 trim：超过 [kMinedSentenceHistoryLimit] 时按 id 升序删除最旧的超额行。
  Future<void> _trimMinedSentences() async {
    final int total = await minedSentences.count().getSingle();
    final int excess = total - kMinedSentenceHistoryLimit;
    if (excess <= 0) return;
    final List<MinedSentenceRow> oldest = await (select(minedSentences)
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(excess))
        .get();
    final List<int> ids = oldest.map((r) => r.id).toList(growable: false);
    if (ids.isEmpty) return;
    await (delete(minedSentences)..where((t) => t.id.isIn(ids))).go();
  }

  // ── dictionary metadata ─────────────────────────────────────────
  Future<List<DictionaryMetaRow>> getAllDictionaryMetadata() =>
      select(dictionaryMetadata).get();

  Future<void> upsertDictionaryMeta(DictionaryMetadataCompanion meta) =>
      into(dictionaryMetadata).insertOnConflictUpdate(meta);

  Future<int> deleteDictionaryMeta(String name) =>
      (delete(dictionaryMetadata)..where((t) => t.name.equals(name))).go();

  Future<int> clearAllDictionaryMeta() => delete(dictionaryMetadata).go();

  // ── dictionary history ──────────────────────────────────────────
  Future<List<DictionaryHistoryRow>> getAllDictionaryHistory() =>
      (select(dictionaryHistory)
            ..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .get();

  Future<void> replaceAllDictionaryHistory(
          List<DictionaryHistoryCompanion> items) =>
      transaction(() async {
        await delete(dictionaryHistory).go();
        await batch((b) {
          for (final item in items) {
            b.insert(dictionaryHistory, item);
          }
        });
      });

  Future<int> clearDictionaryHistory() => delete(dictionaryHistory).go();

  // ── clipboard history ──────────────────
  Future<List<ClipboardHistoryRow>> getAllClipboardHistory() =>
      (select(clipboardHistory)..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .get();

  Future<void> replaceAllClipboardHistory(
          List<ClipboardHistoryCompanion> items) =>
      transaction(() async {
        await delete(clipboardHistory).go();
        await batch((b) {
          for (final item in items) {
            b.insert(clipboardHistory, item);
          }
        });
      });

  Future<int> clearClipboardHistory() => delete(clipboardHistory).go();

  // ── epub books ──────────────────────────────────────────────────
  Future<List<EpubBookRow>> getAllEpubBooks() =>
      (select(epubBooks)..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  /// 监听 EPUB 书 bookKey 集合，供书架在任意导入路径落库后自动刷新（同
  /// [watchVideoBookUids]，BUG-793）。消费方按集合 `.distinct` 去重，改作者/封面等
  /// 纯列更新（集合不变）不触发重算。
  Stream<List<String>> watchEpubBookKeys() =>
      select(epubBooks).map((EpubBookRow row) => row.bookKey).watch();

  Future<EpubBookRow?> getEpubBook(String bookKey) =>
      (select(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  /// 按 extractDir 反查书（CSS 编辑器只有 extractDir，需拿 bookKey 记 book_custom_css）。
  Future<EpubBookRow?> getEpubBookByExtractDir(String extractDir) =>
      (select(epubBooks)
            ..where((t) => t.extractDir.equals(extractDir))
            ..limit(1))
          .getSingleOrNull();

  /// 把 [bookKey] 的书标记为「已读完」（[at] 非 null）或清除完成（[at] == null）。
  /// 书架卡菜单手动切换「标记为已读完/取消」时调用。返回受影响行数。有声书共用同一列
  /// （其配对 EpubBooks 行的 bookKey），故无需 SRT 专用方法。
  Future<int> setEpubBookCompleted(String bookKey, DateTime? at) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
          .write(EpubBooksCompanion(completedAt: Value(at)));

  /// 读到全书末尾时自动写完成时间戳——仅在当前未完成（completed_at IS NULL）时写入，
  /// 幂等：已手动/已自动完成过的书重复读到末尾不刷新时间戳，绝不覆盖用户已手动清除的
  /// 状态（用户取消完成后再读到末尾会重新自动置上，属预期）。返回受影响行数。
  Future<int> markEpubBookCompletedIfUnset(String bookKey, DateTime at) =>
      (update(epubBooks)
            ..where((t) => t.bookKey.equals(bookKey) & t.completedAt.isNull()))
          .write(EpubBooksCompanion(completedAt: Value(at)));

  /// 当前所有「已完成」书的 bookKey 集合（completed_at 非 null），供书架概览
  /// 「Completed」统计与卡片完成角标一次性取用（EPUB 小说卡按自身 bookKey、有声书
  /// SRT 卡按其配对 bookKey 命中同一集合）。
  Future<Set<String>> getCompletedEpubBookKeys() async {
    final query = selectOnly(epubBooks)
      ..addColumns([epubBooks.bookKey])
      ..where(epubBooks.completedAt.isNotNull());
    final List<TypedResult> rows = await query.get();
    return rows.map((TypedResult row) => row.read(epubBooks.bookKey)!).toSet();
  }

  /// Inserts a book; returns its bookKey (the primary key) on success.
  Future<String> insertEpubBook(EpubBooksCompanion book) async {
    await into(epubBooks).insert(book);
    // Re-adding a book cancels any prior deletion tombstone so a later merge
    // may bring its data again (TODO-1195 part B).
    await clearBookTombstone(book.bookKey.value);
    // 删除传播：重新导入同 bookKey 的书清除其 sync 删除墓碑（防「删了又加、墓碑还在」
    // 被 compare 误判成待删）。
    await clearSyncDeletionTombstone('book', book.bookKey.value);
    return book.bookKey.value;
  }

  // ── book tombstones (TODO-1195 part B) ──────────────────────────────
  /// Records that [bookKey] was deleted, so a subsequent backup MERGE import
  /// never resurrects it from an old backup. Idempotent (upsert on the PK).
  Future<void> insertBookTombstone(String bookKey) =>
      into(bookTombstones).insertOnConflictUpdate(
        BookTombstonesCompanion.insert(
          bookKey: bookKey,
          deletedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

  /// Removes the deletion tombstone for [bookKey] (called when the book is
  /// re-added). Returns the number of rows deleted (0 when none existed).
  Future<int> clearBookTombstone(String bookKey) =>
      (delete(bookTombstones)..where((t) => t.bookKey.equals(bookKey))).go();

  /// The set of book_keys currently tombstoned (deleted and not re-added).
  Future<Set<String>> getBookTombstoneKeys() async {
    final List<BookTombstoneRow> rows = await select(bookTombstones).get();
    return rows.map((BookTombstoneRow r) => r.bookKey).toSet();
  }

  // ── statistics tombstones (TODO-1204 后续：统计删除) ─────────────────
  /// sourceType 常量：与统计聚合 / lookup_mining_counters 的 source_type 同值。
  static const String statSourceBook = 'book';
  static const String statSourceVideo = 'video';

  /// 记一条统计删除墓碑 (title, sourceType)：用户在统计页删除某本书/视频的统计后，
  /// 云同步 [applySnapshotToLocal] 与备份合并 MAX-union INSERT 会跳过它，避免 peer /
  /// 旧备份把删掉的书统计复活。幂等（upsert on PK {title, sourceType}）。
  Future<void> insertStatisticsTombstone(String title, String sourceType) =>
      into(statisticsTombstones).insertOnConflictUpdate(
        StatisticsTombstonesCompanion.insert(
          title: title,
          sourceType: sourceType,
          deletedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

  /// 清除 (title, sourceType) 的统计删除墓碑（用户又读该书 / 查词、新写当日统计时
  /// 调用，让该书统计重新生效）。返回删除的行数（无墓碑时 0）。
  Future<int> clearStatisticsTombstone(String title, String sourceType) =>
      (delete(statisticsTombstones)
            ..where(
                (t) => t.title.equals(title) & t.sourceType.equals(sourceType)))
          .go();

  /// 当前全部统计墓碑键 (title, sourceType) 集合，供 [applySnapshotToLocal] 在写回
  /// 合并快照时按键跳过被删的书统计。
  Future<Set<(String, String)>> getStatisticsTombstoneKeys() async {
    final List<StatisticsTombstoneRow> rows =
        await select(statisticsTombstones).get();
    return rows
        .map((StatisticsTombstoneRow r) => (r.title, r.sourceType))
        .toSet();
  }

  /// 删除某本书（按 [title] 聚合）的**纯统计**：阅读时长/字数（reading_statistics）与
  /// 查词/制卡计数（lookup_mining_counters 的 book 行）。同一事务内立一条 book 墓碑，
  /// 防止云同步 / 备份合并把 peer / 旧备份里的旧数字复活。
  ///
  /// **不触碰用户内容**：不删 mined_sentences（制卡历史，收藏夹页展示、可跳回原文）、
  /// 不删 favorite_words / favorite_sentences（收藏）。小时日志（reading_hourly_logs）
  /// 只按 (dateKey, hour) 聚合、不带 title，无法按书精确清理，故不动（全局时段分布仍
  /// 含该书历史贡献，属已知精度边界）。
  Future<void> deleteReadingStatisticsForTitle(String title) =>
      transaction(() async {
        await (delete(readingStatistics)..where((t) => t.title.equals(title)))
            .go();
        await (delete(lookupMiningCounters)
              ..where((t) =>
                  t.title.equals(title) & t.sourceType.equals(statSourceBook)))
            .go();
        await insertStatisticsTombstone(title, statSourceBook);
      });

  /// 删除某视频（按 [title] 聚合）的纯统计：观看时长/字幕字数（video_watch_statistics）
  /// 与查词/制卡计数（lookup_mining_counters 的 video 行）。同一事务内立一条 video
  /// 墓碑防复活。与 [deleteReadingStatisticsForTitle] 同样不动收藏 / 制卡历史 / 小时日志。
  Future<void> deleteVideoStatisticsForTitle(String title) =>
      transaction(() async {
        await (delete(videoWatchStatistics)
              ..where((t) => t.title.equals(title)))
            .go();
        await (delete(lookupMiningCounters)
              ..where((t) =>
                  t.title.equals(title) & t.sourceType.equals(statSourceVideo)))
            .go();
        await insertStatisticsTombstone(title, statSourceVideo);
      });

  /// TODO-1322: 一键清空**全部阅读统计**（book 域纯统计数字）：阅读时长 / 字数
  /// (reading_statistics)、按小时时段日志 (reading_hourly_logs)、per-book 查词 / 制卡
  /// 计数 (lookup_mining_counters 的 book 行) 与全局按日制卡计数 (mining_statistics 的
  /// book 行)。一次事务原子清空。
  ///
  /// **绝不触碰用户内容**：收藏词 / 句 (favorite_words / favorite_sentences)、制卡历史
  /// (mined_sentences，收藏夹页展示、可跳回原文)、书籍 / 词典本体一律保留（与 per-book
  /// [deleteReadingStatisticsForTitle] 同一「只清纯统计」边界）。
  ///
  /// 与 per-book 删除不同：这是**本地整体重置**，不逐标题写墓碑——墓碑是定向删除的防
  /// 同步复活机制，全量重置若逐 title 立碑会永久毒化标题命名空间、阻断以后重新导入这些
  /// 书的统计。云同步开启时下次聚合仍可能从云端 MAX-union 回灌（清空是本地动作，云端为
  /// 权威源）——属已知边界，不在本方法处理。
  Future<void> clearAllReadingStatistics() => transaction(() async {
        await delete(readingStatistics).go();
        await delete(readingHourlyLogs).go();
        await (delete(lookupMiningCounters)
              ..where((t) => t.sourceType.equals(statSourceBook)))
            .go();
        await (delete(miningStatistics)
              ..where((t) => t.sourceType.equals(statSourceBook)))
            .go();
      });

  /// TODO-1322: 一键清空**全部视频统计**（video 域纯统计数字）：观看时长 / 字幕字数
  /// (video_watch_statistics)、按小时时段日志 (video_hourly_logs)、per-video 查词 / 制卡
  /// 计数 (lookup_mining_counters 的 video 行) 与全局按日制卡计数 (mining_statistics 的
  /// video 行)。与 [clearAllReadingStatistics] 对称，同样不动收藏 / 制卡历史 / 视频本体，
  /// 也不写墓碑。
  Future<void> clearAllVideoStatistics() => transaction(() async {
        await delete(videoWatchStatistics).go();
        await delete(videoHourlyLogs).go();
        await (delete(lookupMiningCounters)
              ..where((t) => t.sourceType.equals(statSourceVideo)))
            .go();
        await (delete(miningStatistics)
              ..where((t) => t.sourceType.equals(statSourceVideo)))
            .go();
      });

  Future<void> updateEpubBookPath(String bookKey, String epubPath) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
          .write(EpubBooksCompanion(epubPath: Value(epubPath)));

  /// Update a book's author (BUG-220). Unlike a title rename (which would
  /// change the primary key bookKey = sanitized title and require a cascading
  /// re-key), the author column is NOT the primary key, so this is a plain
  /// UPDATE with no cascading re-key. Pass a blank/empty [author] to clear
  /// it (stored as NULL) so the detail dialog hides the author line.
  Future<void> updateEpubBookAuthor(String bookKey, String? author) {
    final String? trimmed = author?.trim();
    final String? value = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    return (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
        .write(EpubBooksCompanion(author: Value(value)));
  }

  /// 「书 ↔ 漫画」转化：就地改写一本书的**身份格式**及其连带的产物指针列。
  ///
  /// 主键 `bookKey` 不变，因此 `(mediaType='epub', entryKey=bookKey)` 这个统一媒体
  /// 身份完全不动——合集成员 / 标签 / 阅读进度 / 统计 / Profile / 墓碑全部原地存活，
  /// 零悬挂引用。变的只是「这本书用哪个阅读器打开、产物在哪」：
  /// - [format]：[BookFormat]（阅读器路由的唯一真相源）。收枚举而非裸串——这是
  ///   本列唯一不受常量约束的落库入口，收裸串就等于把「写进未知值」的可能性留在
  ///   运行期，而未知值会让路由静默 fallback 到 EPUB 阅读器、在解析路径出错；
  /// - [epubPath]：漫画指向 `manga.json`，书指向原始 `.epub`/`.pdf` 文件名；
  /// - [coverPath]：漫画取首页页图相对路径，书取原封面。**null = 保持原封面不变**
  ///   （与相邻的 [updateEpubBookContentPaths] 同一约定）——转化从不以「清空封面」
  ///   为目的，若用 `Value(null)` 写穿，调用方一旦漏传就把用户封面静默抹掉；
  /// - [chapterCount] / [chaptersJson]：漫画是页数 + `'[]'`，EPUB 是章数 + 每章
  ///   字数数组（转回书时必须**重新解析**原文件得到，转漫画时被覆盖会丢，故反向
  ///   转化是重建而非撤销）；
  /// - [mangaReadingMode]：仅 `format='manga'` 的行有意义，转成非漫画时必须清 null
  ///   （表约定：其它书身份恒 null）。**这一列 null 是有意义的取值**（漫画上 =
  ///   「跟随页图比例自动判定」，非漫画上 = 唯一合法值），故与 [coverPath] 相反，
  ///   必须无条件写穿，不能沿用「null = 不变」。
  ///
  /// 单条 UPDATE，不动 `extractDir`（三种格式共用同一个书目录）。
  Future<void> updateEpubBookFormat(
    String bookKey, {
    required BookFormat format,
    required String epubPath,
    required int chapterCount,
    required String chaptersJson,
    String? coverPath,
    String? mangaReadingMode,
  }) {
    return (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
        .write(EpubBooksCompanion(
      format: Value(format.dbValue),
      epubPath: Value(epubPath),
      chapterCount: Value(chapterCount),
      chaptersJson: Value(chaptersJson),
      coverPath: coverPath == null ? const Value.absent() : Value(coverPath),
      mangaReadingMode: Value(mangaReadingMode),
    ));
  }

  /// TODO-1192: 重写一本书的 `chaptersJson`（每章元数据 + `characters` 计数 +
  /// `charCaliber` 口径版本）。开书时若发现落库计数是旧口径（含标点/括号/空白），
  /// 按新口径 [japaneseCharCount] 后台重算后回写，使书架总字数与后续统计对齐
  /// hoshi。`chaptersJson` 不是主键（bookKey = sanitized title），plain UPDATE，
  /// 无级联 re-key。
  Future<void> updateEpubBookChaptersJson(
          String bookKey, String chaptersJson) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
          .write(EpubBooksCompanion(chaptersJson: Value(chaptersJson)));

  /// Persist the non-sensitive restart descriptor for a Mihon-backed manga.
  ///
  /// Online manga deliberately reuse [EpubBooks] so the existing shelf,
  /// collections, tags and reader identity keep working. The descriptor only
  /// contains extension/source identities, manga metadata and chapter URLs;
  /// cookies, request headers and bearer tokens must never be written here.
  Future<void> updateEpubBookMihonState(
    String bookKey, {
    required String sourceMetadata,
    required int chapterCount,
    required String chaptersJson,
  }) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
        EpubBooksCompanion(
          sourceMetadata: Value(sourceMetadata),
          chapterCount: Value(chapterCount),
          chaptersJson: Value(chaptersJson),
        ),
      );

  /// Rewrites a book's on-disk content paths (full-data backup restore rebases
  /// absolute paths to this device's roots). Only supplied fields are written;
  /// null leaves a column unchanged.
  Future<void> updateEpubBookContentPaths(
    String bookKey, {
    String? epubPath,
    String? extractDir,
    String? coverPath,
  }) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
        EpubBooksCompanion(
          epubPath: epubPath == null ? const Value.absent() : Value(epubPath),
          extractDir:
              extractDir == null ? const Value.absent() : Value(extractDir),
          coverPath:
              coverPath == null ? const Value.absent() : Value(coverPath),
        ),
      );

  /// Rewrites an audiobook's on-disk paths (full-data backup restore). Only
  /// supplied fields are written. `alignmentPath` is non-null in the schema, so
  /// callers that rebase it always pass a value.
  Future<void> updateAudiobookPaths(
    String bookKey, {
    String? audioRoot,
    String? audioPathsJson,
    String? alignmentPath,
  }) =>
      (update(audiobooks)..where((t) => t.bookKey.equals(bookKey))).write(
        AudiobooksCompanion(
          audioRoot:
              audioRoot == null ? const Value.absent() : Value(audioRoot),
          audioPathsJson: audioPathsJson == null
              ? const Value.absent()
              : Value(audioPathsJson),
          alignmentPath: alignmentPath == null
              ? const Value.absent()
              : Value(alignmentPath),
        ),
      );

  /// Deletes a book and all of its dependent rows in one transaction. When
  /// [tombstone] is true (a user-initiated shelf/library delete), a
  /// `book_tombstones` row is recorded so a later backup MERGE import never
  /// resurrects this book from an old backup (TODO-1195 part B). Internal
  /// deletes that are NOT user intent (e.g. an import-rollback, or stripping a
  /// book from an export copy) pass the default false so no tombstone leaks.
  Future<int> deleteEpubBook(String bookKey, {bool tombstone = false}) =>
      transaction(() async {
        await (delete(readerPositions)..where((t) => t.bookKey.equals(bookKey)))
            .go();
        // bookmarks / book_tag_mappings declare ON DELETE CASCADE on
        // epub_books(bookKey), but we delete them explicitly rather than rely on
        // the cascade: this stays correct regardless of the runtime
        // foreign_keys pragma state and documents the full set of dependent
        // rows in one place.
        await (delete(bookmarks)..where((t) => t.bookKey.equals(bookKey))).go();
        // SRT books linked to this epub key their cues on srt_books.uid, NOT
        // the epub bookKey, so delete those cues before dropping the srt rows.
        // (HBK-AUDIT-041 follow-up: deleteEpubBook owns the full cascade; the
        // reader source no longer deletes these rows itself.)
        final List<String> srtUids = await (selectOnly(srtBooks)
              ..addColumns([srtBooks.uid])
              ..where(srtBooks.bookKey.equals(bookKey)))
            .map((r) => r.read(srtBooks.uid)!)
            .get();
        for (final String uid in srtUids) {
          await (delete(audioCues)..where((t) => t.bookKey.equals(uid))).go();
        }
        await (delete(srtBooks)..where((t) => t.bookKey.equals(bookKey))).go();
        // Audiobook + its cues are keyed directly by bookKey now.
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookKey))).go();
        await (delete(audiobooks)..where((t) => t.bookKey.equals(bookKey)))
            .go();
        // TODO-616：同事务清 shelf_entry（mediaType='epub'、entryKey=bookKey）。
        // 若该书还登记过 'srt' 行（EPUB 附属有声书），deleteAudiobookByBookKey 已
        // 幂等清，此处只清 'epub' 行。
        await deleteShelfEntry(MediaKind.epub, bookKey);
        if (tombstone) {
          await into(bookTombstones).insertOnConflictUpdate(
            BookTombstonesCompanion.insert(
              bookKey: bookKey,
              deletedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
        return (delete(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
            .go();
      });

  // ── book tags ───────────────────────────────────────────────────
  Future<List<BookTagRow>> getAllTags() => (select(bookTags)
        ..orderBy([
          (t) => OrderingTerm.asc(t.sortOrder),
          (t) => OrderingTerm.asc(t.createdAt),
        ]))
      .get();

  Future<List<BookTagRow>> getTagsForBook(String bookKey) {
    final query = select(bookTags).join([
      innerJoin(
        bookTagMappings,
        bookTagMappings.tagId.equalsExp(bookTags.id),
      ),
    ])
      ..where(bookTagMappings.bookKey.equals(bookKey))
      ..orderBy([OrderingTerm.asc(bookTags.createdAt)]);
    return query.map((row) => row.readTable(bookTags)).get();
  }

  Future<int> createTag(String name, int colorValue) async {
    final maxQuery = selectOnly(bookTags)
      ..addColumns([bookTags.sortOrder.max()]);
    final maxRow = await maxQuery.getSingleOrNull();
    final int nextOrder = (maxRow?.read(bookTags.sortOrder.max()) ?? 0) + 1;
    return into(bookTags).insert(
      BookTagsCompanion.insert(
        name: name,
        colorValue: Value(colorValue),
        sortOrder: Value(nextOrder),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 按标签名取或建标签，返回其 id（TODO-1165）。
  ///
  /// 标签是每设备本地数据（[BookTags].id autoincrement，各设备不一致），跨设备
  /// 同步/下载重建标签映射只能按 name 传递、落地端按名归一。命中已存在同名标签
  /// 返回其 id（幂等，绝不建重复行——[BookTags].name 有 UNIQUE 约束）；否则以默认
  /// 颜色新建并返回新 id。与 [BackupMergeEngine] 的 name-based UNION 合并同语义。
  Future<int> getOrCreateTagByName(String name) async {
    // 原子 get-or-create：INSERT OR IGNORE 撞 [BookTags].name UNIQUE 时静默忽略，
    // 随后 select 必命中——消除 select-then-insert 的竞态（两并发下载流带同一尚不
    // 存在的 tag 名时，旧实现会一个插入成功、另一个撞 UNIQUE 抛异常丢标签）。命中
    // 既有行时 insertOrIgnore 整条无操作，既有色值/排序不被覆盖；仅新建才给默认灰
    // + 末位排序（与 [createTag] 语义一致）。
    final maxRow = await (selectOnly(bookTags)
          ..addColumns([bookTags.sortOrder.max()]))
        .getSingleOrNull();
    final int nextOrder = (maxRow?.read(bookTags.sortOrder.max()) ?? 0) + 1;
    await into(bookTags).insert(
      BookTagsCompanion.insert(
        name: name,
        colorValue: const Value(0xFF9E9E9E),
        sortOrder: Value(nextOrder),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
      mode: InsertMode.insertOrIgnore,
    );
    final BookTagRow row = await (select(bookTags)
          ..where((t) => t.name.equals(name))
          ..limit(1))
        .getSingle();
    return row.id;
  }

  Future<void> updateTag(int id, {String? name, int? colorValue}) =>
      (update(bookTags)..where((t) => t.id.equals(id))).write(
        BookTagsCompanion(
          name: name != null ? Value(name) : const Value.absent(),
          colorValue:
              colorValue != null ? Value(colorValue) : const Value.absent(),
        ),
      );

  Future<int> deleteTag(int id) =>
      (delete(bookTags)..where((t) => t.id.equals(id))).go();

  Future<void> setTagsForBook(String bookKey, Set<int> tagIds) =>
      transaction(() async {
        final int now = DateTime.now().millisecondsSinceEpoch;
        final existing = await (select(bookTagMappings)
              ..where((t) => t.bookKey.equals(bookKey)))
            .get();
        final existingTagIds = existing.map((e) => e.tagId).toSet();

        final toRemove = existingTagIds.difference(tagIds);
        final toAdd = tagIds.difference(existingTagIds);

        for (final tagId in toRemove) {
          final String? name = await _tagNameById(tagId);
          await (delete(bookTagMappings)
                ..where(
                    (t) => t.bookKey.equals(bookKey) & t.tagId.equals(tagId)))
              .go();
          if (name != null)
            await _upsertTagTombstone(bookKey, MediaKind.epub, name, now);
        }
        for (final tagId in toAdd) {
          await _upsertBookTagMappingWithTime(bookKey, tagId, now);
          final String? name = await _tagNameById(tagId);
          if (name != null)
            await _clearTagTombstone(bookKey, MediaKind.epub, name);
        }
      });

  Future<void> addTagToBook(String bookKey, int tagId) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _upsertBookTagMappingWithTime(bookKey, tagId, now);
    final String? name = await _tagNameById(tagId);
    if (name != null) await _clearTagTombstone(bookKey, MediaKind.epub, name);
  }

  Future<void> removeTagFromBook(String bookKey, int tagId) async {
    final String? name = await _tagNameById(tagId);
    await (delete(bookTagMappings)
          ..where((t) => t.bookKey.equals(bookKey) & t.tagId.equals(tagId)))
        .go();
    if (name != null) {
      await _upsertTagTombstone(
          bookKey, MediaKind.epub, name, DateTime.now().millisecondsSinceEpoch);
    }
  }

  Future<Set<String>> getBookKeysForAllTags(Set<int> tagIds) async {
    if (tagIds.isEmpty) return {};
    final tagCount = tagIds.length;
    final placeholders = List.generate(tagCount, (_) => '?').join(',');
    final variables = <Variable>[
      ...tagIds.map((id) => Variable<int>(id)),
      Variable<int>(tagCount),
    ];
    final rows = await customSelect(
      'SELECT book_key FROM book_tag_mappings '
      'WHERE tag_id IN ($placeholders) '
      'GROUP BY book_key '
      'HAVING COUNT(DISTINCT tag_id) = ?',
      variables: variables,
    ).get();
    return rows.map((row) => row.read<String>('book_key')).toSet();
  }

  Future<List<BookTagMappingRow>> getAllBookTagMappings() =>
      select(bookTagMappings).get();

  /// 全部合集↔标签映射（批量，供 `collectionTagMapProvider` 组装
  /// `Map<collectionId, List<BookTagRow>>`，让书架/视频列表的合集行也能展示标签
  /// chip——与书/视频卡的批量标签 map 同形）。
  Future<List<CollectionTagMappingRow>> getAllCollectionTagMappings() =>
      select(collectionTagMappings).get();

  Future<void> reorderTags(List<int> orderedTagIds) => transaction(() async {
        for (int i = 0; i < orderedTagIds.length; i++) {
          await (update(bookTags)..where((t) => t.id.equals(orderedTagIds[i])))
              .write(BookTagsCompanion(sortOrder: Value(i)));
        }
      });

  /// 某标签下的条目数量 = EPUB + 有声书(SRT) + 视频 + 游戏四张映射表各自命中该
  /// tagId 的行数之和。
  ///
  /// BUG（用户报「标签管理器显示 0 本，实际 2 本」）：旧实现只 COUNT `book_tag_mappings`
  /// （EPUB）一张表，给有声书 / 视频打的标签在管理器里恒显示 0——卡片走分类型正确查询能
  /// 显示标签，计数却漏了另外两张表。BUG-1113 同型：游戏也必须计入。
  /// 合集刻意不计：合集是容器而非条目。
  Future<int> countBooksForTag(int tagId) async {
    final epubCnt = countAll();
    final epubRow = await (selectOnly(bookTagMappings)
          ..where(bookTagMappings.tagId.equals(tagId))
          ..addColumns([epubCnt]))
        .getSingle();
    final srtCnt = countAll();
    final srtRow = await (selectOnly(srtBookTagMappings)
          ..where(srtBookTagMappings.tagId.equals(tagId))
          ..addColumns([srtCnt]))
        .getSingle();
    final videoCnt = countAll();
    final videoRow = await (selectOnly(videoBookTagMappings)
          ..where(videoBookTagMappings.tagId.equals(tagId))
          ..addColumns([videoCnt]))
        .getSingle();
    final gameCnt = countAll();
    final gameRow = await (selectOnly(galgameTagMappings)
          ..where(galgameTagMappings.tagId.equals(tagId))
          ..addColumns([gameCnt]))
        .getSingle();
    final int epub = epubRow.read(epubCnt) ?? 0;
    final int srt = srtRow.read(srtCnt) ?? 0;
    final int video = videoRow.read(videoCnt) ?? 0;
    final int game = gameRow.read(gameCnt) ?? 0;
    return epub + srt + video + game;
  }

  // ── srt book tags ───────────────────────────────────────────────

  Future<List<BookTagRow>> getTagsForSrtBook(int srtBookId) {
    final query = select(bookTags).join([
      innerJoin(
        srtBookTagMappings,
        srtBookTagMappings.tagId.equalsExp(bookTags.id),
      ),
    ])
      ..where(srtBookTagMappings.srtBookId.equals(srtBookId))
      ..orderBy([OrderingTerm.asc(bookTags.createdAt)]);
    return query.map((row) => row.readTable(bookTags)).get();
  }

  Future<void> addTagToSrtBook(int srtBookId, int tagId) =>
      into(srtBookTagMappings).insert(
        SrtBookTagMappingsCompanion.insert(srtBookId: srtBookId, tagId: tagId),
        mode: InsertMode.insertOrIgnore,
      );

  Future<void> removeTagFromSrtBook(int srtBookId, int tagId) => (delete(
          srtBookTagMappings)
        ..where((t) => t.srtBookId.equals(srtBookId) & t.tagId.equals(tagId)))
      .go();

  Future<List<SrtBookTagMappingRow>> getAllSrtBookTagMappings() =>
      select(srtBookTagMappings).get();

  Future<Set<int>> getSrtBookIdsForAllTags(Set<int> tagIds) async {
    if (tagIds.isEmpty) return {};
    final tagCount = tagIds.length;
    final placeholders = List.generate(tagCount, (_) => '?').join(',');
    final variables = <Variable>[
      ...tagIds.map((id) => Variable<int>(id)),
      Variable<int>(tagCount),
    ];
    final rows = await customSelect(
      'SELECT srt_book_id FROM srt_book_tag_mappings '
      'WHERE tag_id IN ($placeholders) '
      'GROUP BY srt_book_id '
      'HAVING COUNT(DISTINCT tag_id) = ?',
      variables: variables,
    ).get();
    return rows.map((row) => row.read<int>('srt_book_id')).toSet();
  }

  // ── video book tags ─────────────────────────────────────────────
  // 视频书复用共享 BookTags 标签池，映射经 video_book_tag_mappings。
  // 全套镜像 SRT 标签 API，键从 srtBookId(int) 换成 videoBookUid(String)。

  Future<List<BookTagRow>> getTagsForVideoBook(String videoBookUid) {
    final query = select(bookTags).join([
      innerJoin(
        videoBookTagMappings,
        videoBookTagMappings.tagId.equalsExp(bookTags.id),
      ),
    ])
      ..where(videoBookTagMappings.bookUid.equals(videoBookUid))
      ..orderBy([OrderingTerm.asc(bookTags.createdAt)]);
    return query.map((row) => row.readTable(bookTags)).get();
  }

  Future<void> addTagToVideoBook(String videoBookUid, int tagId) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _upsertVideoTagMappingWithTime(videoBookUid, tagId, now);
    final String? name = await _tagNameById(tagId);
    if (name != null)
      await _clearTagTombstone(videoBookUid, MediaKind.video, name);
  }

  Future<void> removeTagFromVideoBook(String videoBookUid, int tagId) async {
    final String? name = await _tagNameById(tagId);
    await (delete(videoBookTagMappings)
          ..where(
              (t) => t.bookUid.equals(videoBookUid) & t.tagId.equals(tagId)))
        .go();
    if (name != null) {
      await _upsertTagTombstone(videoBookUid, MediaKind.video, name,
          DateTime.now().millisecondsSinceEpoch);
    }
  }

  // ── 合集标签（复用 BookTags 池；只增不删并集，无墓碑——见 collection-tags 设计 §5）──

  /// 合集当前挂的标签（按 createdAt 升序，与 getTagsForBook 一致）。
  Future<List<BookTagRow>> getTagsForCollection(int collectionId) {
    final query = select(bookTags).join([
      innerJoin(
        collectionTagMappings,
        collectionTagMappings.tagId.equalsExp(bookTags.id),
      ),
    ])
      ..where(collectionTagMappings.collectionId.equals(collectionId))
      ..orderBy([OrderingTerm.asc(bookTags.createdAt)]);
    return query.map((row) => row.readTable(bookTags)).get();
  }

  /// 给合集加标签（INSERT OR IGNORE 幂等；不写墓碑——合集标签同步不消费墓碑）。
  Future<void> addTagToCollection(int collectionId, int tagId) async {
    await into(collectionTagMappings).insert(
      CollectionTagMappingsCompanion.insert(
        collectionId: collectionId,
        tagId: tagId,
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// 从合集移除标签（纯 DELETE，本地生效；同步不传播移除——同书/视频标签现状）。
  Future<void> removeTagFromCollection(int collectionId, int tagId) async {
    await (delete(collectionTagMappings)
          ..where((t) =>
              t.collectionId.equals(collectionId) & t.tagId.equals(tagId)))
        .go();
  }

  /// 含【全部】选中标签的合集 id（AND 语义，仿 getBookKeysForAllTags）。空集返回空。
  Future<Set<int>> getCollectionIdsForAllTags(Set<int> tagIds) async {
    if (tagIds.isEmpty) return <int>{};
    final int tagCount = tagIds.length;
    final String placeholders = List.generate(tagCount, (_) => '?').join(',');
    final List<Variable> variables = <Variable>[
      ...tagIds.map((id) => Variable<int>(id)),
      Variable<int>(tagCount),
    ];
    final rows = await customSelect(
      'SELECT collection_id FROM collection_tag_mappings '
      'WHERE tag_id IN ($placeholders) '
      'GROUP BY collection_id '
      'HAVING COUNT(DISTINCT tag_id) = ?',
      variables: variables,
    ).get();
    return rows.map((row) => row.read<int>('collection_id')).toSet();
  }

  // ── 游戏标签（v59 / BUG-1113；复用 BookTags 池；仅本机）──────────────

  Future<List<BookTagRow>> getTagsForGame(String gameId) {
    final query = select(bookTags).join([
      innerJoin(
        galgameTagMappings,
        galgameTagMappings.tagId.equalsExp(bookTags.id),
      ),
    ])
      ..where(galgameTagMappings.gameId.equals(gameId))
      ..orderBy([OrderingTerm.asc(bookTags.createdAt)]);
    return query.map((row) => row.readTable(bookTags)).get();
  }

  Future<void> addTagToGame(String gameId, int tagId) async {
    await into(galgameTagMappings).insert(
      GalgameTagMappingsCompanion.insert(gameId: gameId, tagId: tagId),
      mode: InsertMode.insertOrIgnore,
    );
  }

  Future<void> removeTagFromGame(String gameId, int tagId) async {
    await (delete(galgameTagMappings)
          ..where((t) => t.gameId.equals(gameId) & t.tagId.equals(tagId)))
        .go();
  }

  Future<void> setTagsForGame(String gameId, Set<int> tagIds) =>
      transaction(() async {
        final List<GalgameTagMappingRow> existing =
            await (select(galgameTagMappings)
                  ..where((t) => t.gameId.equals(gameId)))
                .get();
        final Set<int> existingTagIds =
            existing.map((GalgameTagMappingRow e) => e.tagId).toSet();
        for (final int tagId in existingTagIds.difference(tagIds)) {
          await removeTagFromGame(gameId, tagId);
        }
        for (final int tagId in tagIds.difference(existingTagIds)) {
          await addTagToGame(gameId, tagId);
        }
      });

  Future<Set<String>> getGameIdsForAllTags(Set<int> tagIds) async {
    if (tagIds.isEmpty) return <String>{};
    final int tagCount = tagIds.length;
    final String placeholders = List.generate(tagCount, (_) => '?').join(',');
    final List<Variable> variables = <Variable>[
      ...tagIds.map((id) => Variable<int>(id)),
      Variable<int>(tagCount),
    ];
    final rows = await customSelect(
      'SELECT game_id FROM galgame_tag_mappings '
      'WHERE tag_id IN ($placeholders) '
      'GROUP BY game_id '
      'HAVING COUNT(DISTINCT tag_id) = ?',
      variables: variables,
    ).get();
    return rows.map((row) => row.read<String>('game_id')).toSet();
  }

  Future<List<GalgameTagMappingRow>> getAllGameTagMappings() =>
      select(galgameTagMappings).get();

  Future<void> setTagsForVideoBook(String videoBookUid, Set<int> tagIds) =>
      transaction(() async {
        final int now = DateTime.now().millisecondsSinceEpoch;
        final existing = await (select(videoBookTagMappings)
              ..where((t) => t.bookUid.equals(videoBookUid)))
            .get();
        final existingTagIds = existing.map((e) => e.tagId).toSet();

        final toRemove = existingTagIds.difference(tagIds);
        final toAdd = tagIds.difference(existingTagIds);

        for (final tagId in toRemove) {
          final String? name = await _tagNameById(tagId);
          await (delete(videoBookTagMappings)
                ..where((t) =>
                    t.bookUid.equals(videoBookUid) & t.tagId.equals(tagId)))
              .go();
          if (name != null) {
            await _upsertTagTombstone(videoBookUid, MediaKind.video, name, now);
          }
        }
        for (final tagId in toAdd) {
          await _upsertVideoTagMappingWithTime(videoBookUid, tagId, now);
          final String? name = await _tagNameById(tagId);
          if (name != null)
            await _clearTagTombstone(videoBookUid, MediaKind.video, name);
        }
      });

  Future<List<VideoBookTagMappingRow>> getAllVideoBookTagMappings() =>
      select(videoBookTagMappings).get();

  // ── tags 跨端同步（LWW-element-set：added_at vs 墓碑 deleted_at）──────────────
  // 标签跨设备身份 = name。sync 合并按名并集两端「当前标签(带 addedAt)」与「移除墓碑
  // (带 deletedAt)」，逐名 max(addedAt) vs max(deletedAt) 裁决 present/removed，防复活/
  // 防误删。UI 加/删标签写 addedAt/墓碑，让本地操作也进入同一 LWW 时钟。

  Future<String?> _tagNameById(int tagId) async {
    final BookTagRow? row = await (select(bookTags)
          ..where((t) => t.id.equals(tagId))
          ..limit(1))
        .getSingleOrNull();
    return row?.name;
  }

  /// 当前书 [bookKey] 的标签「名 → 加入毫秒戳」（sync 合并的 add 时钟）。
  Future<Map<String, int>> bookTagAddedAtByName(String bookKey) async {
    final rows = await (select(bookTagMappings).join([
      innerJoin(bookTags, bookTags.id.equalsExp(bookTagMappings.tagId)),
    ])
          ..where(bookTagMappings.bookKey.equals(bookKey)))
        .get();
    return <String, int>{
      for (final row in rows)
        row.readTable(bookTags).name: row.readTable(bookTagMappings).addedAt,
    };
  }

  /// 当前视频 [videoBookUid] 的标签「名 → 加入毫秒戳」。
  Future<Map<String, int>> videoTagAddedAtByName(String videoBookUid) async {
    final rows = await (select(videoBookTagMappings).join([
      innerJoin(bookTags, bookTags.id.equalsExp(videoBookTagMappings.tagId)),
    ])
          ..where(videoBookTagMappings.bookUid.equals(videoBookUid)))
        .get();
    return <String, int>{
      for (final row in rows)
        row.readTable(bookTags).name:
            row.readTable(videoBookTagMappings).addedAt,
    };
  }

  /// 某宿主 [itemKey]（[mediaType] 为 [MediaKind.epub]/[MediaKind.video]）的
  /// 标签移除墓碑「名 → 移除毫秒戳」。
  Future<Map<String, int>> tagTombstonesByName(
      String itemKey, MediaKind mediaType) async {
    final rows = await (select(bookTagMembershipTombstones)
          ..where((t) =>
              t.itemKey.equals(itemKey) &
              t.mediaType.equals(mediaType.dbValue)))
        .get();
    return <String, int>{for (final r in rows) r.tagName: r.deletedAt};
  }

  /// 全库书标签「bookKey → (名 → 加入毫秒戳)」一趟批查。
  ///
  /// 互联 host 清单（listBooks）逐书调 [bookTagAddedAtByName] 是 O(N) 次查询，
  /// 大库拖慢清单端点；这里一条 join 拉全量再按 bookKey 分组，语义与逐书版逐条一致。
  Future<Map<String, Map<String, int>>> allBookTagAddedAtByName() async {
    final rows = await select(bookTagMappings).join([
      innerJoin(bookTags, bookTags.id.equalsExp(bookTagMappings.tagId)),
    ]).get();
    final Map<String, Map<String, int>> out = <String, Map<String, int>>{};
    for (final row in rows) {
      final BookTagMappingRow m = row.readTable(bookTagMappings);
      (out[m.bookKey] ??= <String, int>{})[row.readTable(bookTags).name] =
          m.addedAt;
    }
    return out;
  }

  /// 全库视频标签「videoBookUid → (名 → 加入毫秒戳)」一趟批查（对称
  /// [allBookTagAddedAtByName]，供互联 host listVideos 批量预取）。
  Future<Map<String, Map<String, int>>> allVideoTagAddedAtByName() async {
    final rows = await select(videoBookTagMappings).join([
      innerJoin(bookTags, bookTags.id.equalsExp(videoBookTagMappings.tagId)),
    ]).get();
    final Map<String, Map<String, int>> out = <String, Map<String, int>>{};
    for (final row in rows) {
      final VideoBookTagMappingRow m = row.readTable(videoBookTagMappings);
      (out[m.bookUid] ??= <String, int>{})[row.readTable(bookTags).name] =
          m.addedAt;
    }
    return out;
  }

  /// 某 [mediaType] 全部标签移除墓碑「itemKey → (名 → 移除毫秒戳)」一趟批查
  /// （替代清单端点逐条 [tagTombstonesByName]）。
  Future<Map<String, Map<String, int>>> allTagTombstonesByName(
      MediaKind mediaType) async {
    final rows = await (select(bookTagMembershipTombstones)
          ..where((t) => t.mediaType.equals(mediaType.dbValue)))
        .get();
    final Map<String, Map<String, int>> out = <String, Map<String, int>>{};
    for (final r in rows) {
      (out[r.itemKey] ??= <String, int>{})[r.tagName] = r.deletedAt;
    }
    return out;
  }

  Future<void> _upsertTagTombstone(
          String itemKey, MediaKind mediaType, String tagName, int deletedAt) =>
      into(bookTagMembershipTombstones).insertOnConflictUpdate(
        BookTagMembershipTombstonesCompanion.insert(
          itemKey: itemKey,
          mediaType: mediaType.dbValue,
          tagName: tagName,
          deletedAt: deletedAt,
        ),
      );

  Future<void> _clearTagTombstone(
          String itemKey, MediaKind mediaType, String tagName) =>
      (delete(bookTagMembershipTombstones)
            ..where((t) =>
                t.itemKey.equals(itemKey) &
                t.mediaType.equals(mediaType.dbValue) &
                t.tagName.equals(tagName)))
          .go();

  /// upsert 一条 (bookKey, tagId) 映射并写 [addedAt]（无则插入，有则刷新 addedAt）。
  Future<void> _upsertBookTagMappingWithTime(
      String bookKey, int tagId, int addedAt) async {
    final existing = await (select(bookTagMappings)
          ..where((t) => t.bookKey.equals(bookKey) & t.tagId.equals(tagId))
          ..limit(1))
        .getSingleOrNull();
    if (existing == null) {
      await into(bookTagMappings).insert(BookTagMappingsCompanion.insert(
        bookKey: bookKey,
        tagId: tagId,
        addedAt: Value(addedAt),
      ));
    } else {
      await (update(bookTagMappings)..where((t) => t.id.equals(existing.id)))
          .write(BookTagMappingsCompanion(addedAt: Value(addedAt)));
    }
  }

  Future<void> _upsertVideoTagMappingWithTime(
      String videoBookUid, int tagId, int addedAt) async {
    final existing = await (select(videoBookTagMappings)
          ..where((t) => t.bookUid.equals(videoBookUid) & t.tagId.equals(tagId))
          ..limit(1))
        .getSingleOrNull();
    if (existing == null) {
      await into(videoBookTagMappings).insert(
          VideoBookTagMappingsCompanion.insert(
              bookUid: videoBookUid, tagId: tagId, addedAt: Value(addedAt)));
    } else {
      await (update(videoBookTagMappings)
            ..where((t) => t.id.equals(existing.id)))
          .write(VideoBookTagMappingsCompanion(addedAt: Value(addedAt)));
    }
  }

  /// LWW-element-set：把远端标签快照合并进书 [bookKey] 本地状态。
  /// [remoteAddedAt]=远端当前标签名→加入戳；[remoteTombstones]=远端移除墓碑名→移除戳。
  /// 按名并集两端 add 时钟与墓碑时钟，逐名 max(add) > max(removed) ⇒ present（写映射，
  /// addedAt=合并后 add 戳）；否则 removed（删映射 + 写墓碑，deletedAt=合并后墓碑戳）。
  /// 幂等；无远端墓碑（旧端只传名单）时以 [nowMs] 视作 add 戳，退化为并集只增（向后兼容）。
  Future<void> mergeRemoteBookTags(
    String bookKey, {
    required Map<String, int> remoteAddedAt,
    Map<String, int> remoteTombstones = const <String, int>{},
  }) =>
      transaction(() async {
        final Map<String, int> localAdded = await bookTagAddedAtByName(bookKey);
        final Map<String, int> localTomb =
            await tagTombstonesByName(bookKey, MediaKind.epub);
        final _MergedTagState merged = _mergeTagClocks(
            localAdded, remoteAddedAt, localTomb, remoteTombstones);
        for (final MapEntry<String, int> e in merged.present.entries) {
          final int tagId = await getOrCreateTagByName(e.key);
          await _upsertBookTagMappingWithTime(bookKey, tagId, e.value);
          await _clearTagTombstone(bookKey, MediaKind.epub, e.key);
        }
        for (final MapEntry<String, int> e in merged.tombstones.entries) {
          final int? tagId = await _tagIdByName(e.key);
          if (tagId != null) await removeTagFromBook(bookKey, tagId);
          await _upsertTagTombstone(bookKey, MediaKind.epub, e.key, e.value);
        }
      });

  /// LWW-element-set：把远端标签快照合并进视频 [videoBookUid] 本地状态（同 [mergeRemoteBookTags]）。
  Future<void> mergeRemoteVideoTags(
    String videoBookUid, {
    required Map<String, int> remoteAddedAt,
    Map<String, int> remoteTombstones = const <String, int>{},
  }) =>
      transaction(() async {
        final Map<String, int> localAdded =
            await videoTagAddedAtByName(videoBookUid);
        final Map<String, int> localTomb =
            await tagTombstonesByName(videoBookUid, MediaKind.video);
        final _MergedTagState merged = _mergeTagClocks(
            localAdded, remoteAddedAt, localTomb, remoteTombstones);
        for (final MapEntry<String, int> e in merged.present.entries) {
          final int tagId = await getOrCreateTagByName(e.key);
          await _upsertVideoTagMappingWithTime(videoBookUid, tagId, e.value);
          await _clearTagTombstone(videoBookUid, MediaKind.video, e.key);
        }
        for (final MapEntry<String, int> e in merged.tombstones.entries) {
          final int? tagId = await _tagIdByName(e.key);
          if (tagId != null) await removeTagFromVideoBook(videoBookUid, tagId);
          await _upsertTagTombstone(
              videoBookUid, MediaKind.video, e.key, e.value);
        }
      });

  Future<int?> _tagIdByName(String name) async {
    final BookTagRow? row = await (select(bookTags)
          ..where((t) => t.name.equals(name))
          ..limit(1))
        .getSingleOrNull();
    return row?.id;
  }

  // ── per-book 自定义 CSS 跨端同步（LWW by updatedAt）──────────────────────────

  /// 记录/刷新书 [bookKey] 的 CSS 文件 [relativePath] 自定义内容（保存时调，updatedAt=now）。
  Future<void> upsertBookCss(
          String bookKey, String relativePath, String content, int updatedAt) =>
      into(bookCustomCss).insertOnConflictUpdate(BookCustomCssRow(
        bookKey: bookKey,
        relativePath: relativePath,
        content: content,
        deleted: false,
        updatedAt: updatedAt,
      ));

  /// 记录书 [bookKey] 的 CSS 文件 [relativePath] 已重置回原始（重置墓碑，updatedAt=now）。
  /// 使「reset」跨端传播（LWW 较新的重置让他端也 reset）。
  Future<void> markBookCssReset(
          String bookKey, String relativePath, int updatedAt) =>
      into(bookCustomCss).insertOnConflictUpdate(BookCustomCssRow(
        bookKey: bookKey,
        relativePath: relativePath,
        content: '',
        deleted: true,
        updatedAt: updatedAt,
      ));

  /// 书 [bookKey] 的全部自定义 CSS 行（含重置墓碑）。sync push 快照用。
  Future<List<BookCustomCssRow>> getBookCssRows(String bookKey) =>
      (select(bookCustomCss)..where((t) => t.bookKey.equals(bookKey))).get();

  // ── 图片防剧透遮罩揭开状态（持久 per-book；书内↔图片库双向同步，BUG-898）──────────

  /// 标记书 [bookKey] 的图片 [imageKey]（extractDir 相对、解码、正斜杠归一路径）已揭开
  /// 遮罩。幂等 upsert（重复揭开刷新 [revealedAt]）。阅读器点击/手柄/音频跨图、图片库
  /// 点开都调它，DB 是唯一真相源。
  Future<void> markImageRevealed(
          String bookKey, String imageKey, int revealedAt) =>
      into(revealedImages).insertOnConflictUpdate(RevealedImageRow(
        bookKey: bookKey,
        imageKey: imageKey,
        revealedAt: revealedAt,
      ));

  /// 一次标记书 [bookKey] 的多张图片已揭开（音频跨多图一次全揭时批量写，省往返）。
  Future<void> markImagesRevealed(
      String bookKey, Iterable<String> imageKeys, int revealedAt) {
    final List<String> keys = imageKeys.toList(growable: false);
    if (keys.isEmpty) return Future<void>.value();
    return batch((Batch b) {
      for (final String k in keys) {
        b.insert(
          revealedImages,
          RevealedImageRow(
              bookKey: bookKey, imageKey: k, revealedAt: revealedAt),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// 书 [bookKey] 全部已揭开图片 key 集合。阅读器打开时读它灌入会话集、图片库渲染时读它
  /// 判断哪些图不遮罩。
  Future<Set<String>> getRevealedImageKeys(String bookKey) async {
    final List<RevealedImageRow> rows = await (select(revealedImages)
          ..where((t) => t.bookKey.equals(bookKey)))
        .get();
    return rows.map((RevealedImageRow r) => r.imageKey).toSet();
  }

  /// 书 [bookKey] 已揭开图片 key 的实时流（图片库/阅读器 live 双向同步：一端揭开另一端
  /// 自动收到更新）。
  Stream<Set<String>> watchRevealedImageKeys(String bookKey) =>
      (select(revealedImages)..where((t) => t.bookKey.equals(bookKey)))
          .watch()
          .map((List<RevealedImageRow> rows) =>
              rows.map((RevealedImageRow r) => r.imageKey).toSet());

  // ── 删除传播墓碑（显式确认式）─────────────────────────────────────────────────

  /// 记一条删除墓碑（本地删资产时调；重复删同键 upsert 刷新 deletedAt，重置发布状态）。
  Future<void> writeSyncDeletionTombstone(
          String mediaType, String itemKey, int deletedAt) =>
      into(syncDeletionTombstones).insertOnConflictUpdate(
          SyncDeletionTombstoneRow(
              mediaType: mediaType,
              itemKey: itemKey,
              deletedAt: deletedAt,
              remotePublishedAt: 0));

  /// 清除某资产的删除墓碑（重新导入 / 新增同 (mediaType, itemKey) 时调，防误删复活）。
  Future<void> clearSyncDeletionTombstone(String mediaType, String itemKey) =>
      (delete(syncDeletionTombstones)
            ..where((t) =>
                t.mediaType.equals(mediaType) & t.itemKey.equals(itemKey)))
          .go();

  /// 全部删除墓碑（sync 发布 / compare 对话框读）。
  Future<List<SyncDeletionTombstoneRow>> getSyncDeletionTombstones() =>
      select(syncDeletionTombstones).get();

  /// 某种资产的删除墓碑。
  Future<List<SyncDeletionTombstoneRow>> getSyncDeletionTombstonesOfType(
          String mediaType) =>
      (select(syncDeletionTombstones)
            ..where((t) => t.mediaType.equals(mediaType)))
          .get();

  /// 标记某墓碑已发布到远端（避免每轮重发；[publishedAt] = 发布时刻）。
  Future<void> markSyncDeletionPublished(
          String mediaType, String itemKey, int publishedAt) =>
      (update(syncDeletionTombstones)
            ..where((t) =>
                t.mediaType.equals(mediaType) & t.itemKey.equals(itemKey)))
          .write(SyncDeletionTombstonesCompanion(
              remotePublishedAt: Value(publishedAt)));

  /// LWW 合并远端 CSS 快照进书 [bookKey]。[remote] 是远端每个 relativePath 的
  /// (content, deleted, updatedAt)。逐 relativePath 比 updatedAt 取较新写本地行；返回
  /// **本地实际发生变化**的 (relativePath, content, deleted) 列表，供调用方把较新内容
  /// 写穿磁盘（BookCssRepository.saveCss / resetFile）——DB 只是时间戳载体，磁盘才是
  /// 渲染真相源。幂等（同快照重复合并第二次返回空）。
  Future<List<({String relativePath, String content, bool deleted})>>
      mergeRemoteBookCss(
    String bookKey,
    Map<String, ({String content, bool deleted, int updatedAt})> remote,
  ) =>
          transaction(() async {
            final Map<String, BookCustomCssRow> localByPath =
                <String, BookCustomCssRow>{
              for (final BookCustomCssRow r in await getBookCssRows(bookKey))
                r.relativePath: r,
            };
            final List<({String relativePath, String content, bool deleted})>
                changed =
                <({String relativePath, String content, bool deleted})>[];
            for (final MapEntry<String,
                    ({String content, bool deleted, int updatedAt})> e
                in remote.entries) {
              final BookCustomCssRow? local = localByPath[e.key];
              // 远端严格更新才落地（相等 / 更旧不动，防每轮写放大 + 保留本地更新）。
              if (local != null && local.updatedAt >= e.value.updatedAt)
                continue;
              await into(bookCustomCss).insertOnConflictUpdate(BookCustomCssRow(
                bookKey: bookKey,
                relativePath: e.key,
                content: e.value.deleted ? '' : e.value.content,
                deleted: e.value.deleted,
                updatedAt: e.value.updatedAt,
              ));
              changed.add((
                relativePath: e.key,
                content: e.value.content,
                deleted: e.value.deleted,
              ));
            }
            return changed;
          });

  Future<Set<String>> getVideoBookUidsForAllTags(Set<int> tagIds) async {
    if (tagIds.isEmpty) return {};
    final tagCount = tagIds.length;
    final placeholders = List.generate(tagCount, (_) => '?').join(',');
    final variables = <Variable>[
      ...tagIds.map((id) => Variable<int>(id)),
      Variable<int>(tagCount),
    ];
    final rows = await customSelect(
      'SELECT book_uid FROM video_book_tag_mappings '
      'WHERE tag_id IN ($placeholders) '
      'GROUP BY book_uid '
      'HAVING COUNT(DISTINCT tag_id) = ?',
      variables: variables,
    ).get();
    return rows.map((row) => row.read<String>('book_uid')).toSet();
  }

  // ── profiles ──────────────────────────────────────────────────────
  Future<List<ProfileRow>> getAllProfiles() =>
      (select(profiles)..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();

  Future<ProfileRow?> getProfileById(int id) =>
      (select(profiles)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<int> insertProfile(ProfilesCompanion p) => into(profiles).insert(p);

  Future<void> updateProfileName(int id, String name) =>
      (update(profiles)..where((t) => t.id.equals(id))).write(
        ProfilesCompanion(
          name: Value(name),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  Future<int> deleteProfile(int id) =>
      (delete(profiles)..where((t) => t.id.equals(id))).go();

  Future<int> countProfiles() async {
    final cnt = countAll();
    final q = selectOnly(profiles)..addColumns([cnt]);
    final row = await q.getSingle();
    return row.read(cnt)!;
  }

  // ── profile settings ─────────────────────────────────────────────
  Future<List<ProfileSettingRow>> getProfileSettings(int profileId) =>
      (select(profileSettings)..where((t) => t.profileId.equals(profileId)))
          .get();

  Future<void> upsertProfileSetting(ProfileSettingsCompanion s) =>
      into(profileSettings).insert(
        s,
        onConflict: DoUpdate(
          (old) => ProfileSettingsCompanion(value: s.value),
          target: [
            profileSettings.profileId,
            profileSettings.category,
            profileSettings.key,
          ],
        ),
      );

  Future<void> replaceProfileSettings(
          int profileId, List<ProfileSettingsCompanion> settings) =>
      transaction(() async {
        await (delete(profileSettings)
              ..where((t) => t.profileId.equals(profileId)))
            .go();
        await batch((b) {
          for (final s in settings) {
            b.insert(profileSettings, s);
          }
        });
      });

  // ── media type profiles ──────────────────────────────────────────
  Future<List<MediaTypeProfileRow>> getAllMediaTypeProfiles() =>
      select(mediaTypeProfiles).get();

  Future<MediaTypeProfileRow?> getMediaTypeProfile(String mediaType) =>
      (select(mediaTypeProfiles)..where((t) => t.mediaType.equals(mediaType)))
          .getSingleOrNull();

  Future<void> setMediaTypeProfile(String mediaType, int profileId) =>
      into(mediaTypeProfiles).insertOnConflictUpdate(
        MediaTypeProfilesCompanion.insert(
          mediaType: mediaType,
          profileId: profileId,
        ),
      );

  Future<int> deleteMediaTypeProfile(String mediaType) =>
      (delete(mediaTypeProfiles)..where((t) => t.mediaType.equals(mediaType)))
          .go();

  // ── book profiles ────────────────────────────────────────────────
  Future<BookProfileRow?> getBookProfile(String bookKey) =>
      (select(bookProfiles)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  Future<void> setBookProfile(String bookKey, int profileId) =>
      into(bookProfiles).insertOnConflictUpdate(
        BookProfilesCompanion.insert(
          bookKey: bookKey,
          profileId: profileId,
        ),
      );

  Future<int> deleteBookProfile(String bookKey) =>
      (delete(bookProfiles)..where((t) => t.bookKey.equals(bookKey))).go();

  // ── sync baselines ──────────────────────────────────────────────
  /// 读某资产某维度的基线版本；无记录返回 null。
  Future<int?> getSyncBaseline(String assetKey, String dimension) async {
    final SyncBaselineRow? row = await (select(syncBaselines)
          ..where((t) =>
              t.assetKey.equals(assetKey) & t.dimension.equals(dimension)))
        .getSingleOrNull();
    return row?.baseVersion;
  }

  /// 写/更新基线版本（主键 assetKey+dimension upsert）。
  Future<void> setSyncBaseline(
    String assetKey,
    String dimension,
    int baseVersion,
  ) =>
      into(syncBaselines).insertOnConflictUpdate(SyncBaselinesCompanion(
        assetKey: Value(assetKey),
        dimension: Value(dimension),
        baseVersion: Value(baseVersion),
      ));

  // ── v16 book-key migration ──────────────────────────────────────
  // Legacy uid prefix that wrapped the int book id in audiobooks/audio_cues/
  // book_profiles and in the uid-style audiobook_pos_ prefs. Single literal so
  // the migration's int-extraction matches what buildLegacyBookUid produced.
  static const String _kLegacyUidPrefix = 'reader_ttu/hoshi://book/';

  /// Delegates to the core-local copy of `sanitizeTtuFilename`
  /// (`../utils/ttu_sanitize.dart`). hibiki_core cannot depend on the app
  /// package, so the core copy stands in for the app truth source
  /// `hibiki/lib/src/sync/ttu_filename.dart`. Core copy and app copy MUST
  /// stay byte-identical: the migrated bookKey has to equal the key
  /// sync/folder code derives from the same title, or cross-device identity
  /// drifts. A source guard (book_key_guard_test) plus the behavioral
  /// parity test (video_book_uid_core_parity_test) lock the two together.
  static String _sanitizeBookKey(String title) => sanitizeTtuFilename(title);

  /// Re-keys every book + all reading data from the autoincrement int id to
  /// bookKey = sanitizeTtuFilename(title). Lossless: builds an id→key map (with
  /// dedup), then rebuilds each table by JOINing through that map.
  ///
  /// Atomicity is the iron rule here — this rewrites user data. drift does NOT
  /// wrap onUpgrade in a transaction by default, so the whole migration body
  /// runs inside an EXPLICIT `transaction()`: it either fully commits or fully
  /// rolls back, leaving user_version at 15 for a safe retry on next launch.
  /// `PRAGMA foreign_keys` is a no-op inside a transaction (SQLite rule), so the
  /// OFF/ON toggles sit OUTSIDE `transaction()`, per drift's "migrations and
  /// foreign keys" guidance. A `foreign_key_check` at the end aborts (rolls
  /// back) the whole migration if any FK relation was left dangling.
  Future<void> _migrateBookKeyV16(Migrator m) async {
    await customStatement('PRAGMA foreign_keys = OFF');
    try {
      await transaction(() async {
        await _runBookKeyMigrationBodyV16();
      });
    } finally {
      await customStatement('PRAGMA foreign_keys = ON');
    }
  }

  /// The full v16 re-key work, run inside the explicit transaction opened by
  /// [_migrateBookKeyV16]. Extracted so the transaction boundary and the
  /// foreign_keys OFF/ON toggles (which must stay outside any transaction) read
  /// cleanly. Throwing anywhere here rolls back the entire migration.
  Future<void> _runBookKeyMigrationBodyV16() async {
    {
      // Guard: only run the re-key when epub_books still carries the legacy
      // autoincrement `id` column. A DB reaching this step with epub_books
      // already created fresh under the v16 generated schema (its PK is
      // `book_key`, no `id`) — e.g. a pre-v5 DB whose from<5 ladder step ran
      // m.createTable(epubBooks) — is already on the target shape, so the whole
      // re-key is a no-op. This also covers synthetic/partial seeds with no
      // epub_books at all (_columnExists implies the table exists). A genuine
      // pre-v16 DB has the int `id` column, so real upgrades still migrate.
      if (!await _columnExists('epub_books', 'id')) {
        return;
      }

      // 1. Read (id, title); compute key + dedup collisions deterministically.
      final List<QueryRow> books =
          await customSelect('SELECT id, title FROM epub_books ORDER BY id')
              .get();
      final Map<int, String> idToKey = <int, String>{};
      final Set<String> used = <String>{};
      for (final QueryRow r in books) {
        final int id = r.read<int>('id');
        String key = _sanitizeBookKey(r.read<String>('title'));
        if (used.contains(key)) {
          for (int i = 2;; i++) {
            final String candidate = '$key ($i)';
            if (!used.contains(candidate)) {
              key = candidate;
              break;
            }
          }
        }
        used.add(key);
        idToKey[id] = key;
      }

      // 2. Temp map table (old_id -> book_key).
      await customStatement('DROP TABLE IF EXISTS _id_key_map');
      await customStatement(
          'CREATE TABLE _id_key_map (old_id INTEGER PRIMARY KEY, book_key TEXT NOT NULL)');
      for (final MapEntry<int, String> e in idToKey.entries) {
        await customStatement(
            'INSERT INTO _id_key_map (old_id, book_key) VALUES (?, ?)',
            <Object?>[e.key, e.value]);
      }

      // 3. epub_books: id PK -> book_key PK.
      await customStatement('''
        CREATE TABLE epub_books_new (
          book_key TEXT NOT NULL PRIMARY KEY,
          title TEXT NOT NULL,
          author TEXT,
          cover_path TEXT,
          epub_path TEXT NOT NULL,
          extract_dir TEXT NOT NULL,
          chapter_count INTEGER NOT NULL,
          chapters_json TEXT NOT NULL,
          toc_json TEXT,
          source_metadata TEXT,
          imported_at INTEGER NOT NULL)''');
      await customStatement('''
        INSERT INTO epub_books_new
        SELECT m.book_key, b.title, b.author, b.cover_path, b.epub_path,
               b.extract_dir, b.chapter_count, b.chapters_json, b.toc_json,
               b.source_metadata, b.imported_at
        FROM epub_books b JOIN _id_key_map m ON m.old_id = b.id''');
      await customStatement('DROP TABLE epub_books');
      await customStatement('ALTER TABLE epub_books_new RENAME TO epub_books');

      // Each relation table is rebuilt ONLY if it still carries its legacy
      // int/uid column. A DB that reached this step with a table already
      // created fresh under the current v16 generated schema (e.g. a pre-v11 DB
      // whose from<11 ladder step ran m.createTable) already has `book_key` and
      // must be left untouched — rebuilding it would JOIN on a non-existent
      // legacy column. Synthetic/partial seeds that lack the table entirely are
      // likewise skipped (column check implies table check).

      // 4. reader_positions: ttu_book_id INT UNIQUE -> book_key TEXT UNIQUE.
      if (await _columnExists('reader_positions', 'ttu_book_id')) {
        await customStatement('''
        CREATE TABLE reader_positions_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL UNIQUE,
          section_index INTEGER NOT NULL,
          norm_char_offset INTEGER NOT NULL,
          ttu_char_offset INTEGER NOT NULL DEFAULT -1,
          updated_at INTEGER NOT NULL)''');
        await customStatement('''
        INSERT INTO reader_positions_new
          (book_key, section_index, norm_char_offset, ttu_char_offset, updated_at)
        SELECT m.book_key, rp.section_index, rp.norm_char_offset,
               rp.ttu_char_offset, rp.updated_at
        FROM reader_positions rp JOIN _id_key_map m ON m.old_id = rp.ttu_book_id''');
        await customStatement('DROP TABLE reader_positions');
        await customStatement(
            'ALTER TABLE reader_positions_new RENAME TO reader_positions');
      }

      // 5. bookmarks: ttu_book_id INT FK -> book_key TEXT FK (cascade).
      if (await _columnExists('bookmarks', 'ttu_book_id')) {
        await customStatement('''
        CREATE TABLE bookmarks_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL REFERENCES epub_books (book_key) ON DELETE CASCADE,
          section_index INTEGER NOT NULL,
          norm_char_offset INTEGER NOT NULL,
          label TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          book_title TEXT,
          page_in_chapter INTEGER,
          total_pages_in_chapter INTEGER)''');
        await customStatement('''
        INSERT INTO bookmarks_new
          (id, book_key, section_index, norm_char_offset, label, created_at,
           book_title, page_in_chapter, total_pages_in_chapter)
        SELECT bm.id, m.book_key, bm.section_index, bm.norm_char_offset,
               bm.label, bm.created_at, bm.book_title, bm.page_in_chapter,
               bm.total_pages_in_chapter
        FROM bookmarks bm JOIN _id_key_map m ON m.old_id = bm.ttu_book_id''');
        await customStatement('DROP TABLE bookmarks');
        await customStatement('ALTER TABLE bookmarks_new RENAME TO bookmarks');
      }

      // 6. book_tag_mappings: book_id INT FK -> book_key TEXT FK (cascade).
      if (await _columnExists('book_tag_mappings', 'book_id')) {
        await customStatement('''
        CREATE TABLE book_tag_mappings_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL REFERENCES epub_books (book_key) ON DELETE CASCADE,
          tag_id INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE,
          UNIQUE (book_key, tag_id))''');
        await customStatement('''
        INSERT INTO book_tag_mappings_new (id, book_key, tag_id)
        SELECT btm.id, m.book_key, btm.tag_id
        FROM book_tag_mappings btm JOIN _id_key_map m ON m.old_id = btm.book_id''');
        await customStatement('DROP TABLE book_tag_mappings');
        await customStatement(
            'ALTER TABLE book_tag_mappings_new RENAME TO book_tag_mappings');
      }

      // 7. srt_books: ttu_book_id INT (0 = standalone) -> book_key TEXT ('').
      //    LEFT JOIN so standalone rows (no mapped epub) keep '' sentinel.
      if (await _columnExists('srt_books', 'ttu_book_id')) {
        await customStatement('''
        CREATE TABLE srt_books_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          uid TEXT NOT NULL UNIQUE,
          title TEXT NOT NULL,
          author TEXT,
          audio_root TEXT,
          audio_paths_json TEXT,
          srt_path TEXT NOT NULL,
          cover_path TEXT,
          imported_at INTEGER NOT NULL,
          book_key TEXT NOT NULL DEFAULT '')''');
        await customStatement('''
        INSERT INTO srt_books_new
          (id, uid, title, author, audio_root, audio_paths_json, srt_path,
           cover_path, imported_at, book_key)
        SELECT sb.id, sb.uid, sb.title, sb.author, sb.audio_root,
               sb.audio_paths_json, sb.srt_path, sb.cover_path, sb.imported_at,
               COALESCE(m.book_key, '')
        FROM srt_books sb LEFT JOIN _id_key_map m ON m.old_id = sb.ttu_book_id''');
        await customStatement('DROP TABLE srt_books');
        await customStatement('ALTER TABLE srt_books_new RENAME TO srt_books');
      }

      // 8. audiobooks: book_uid 'reader_ttu/hoshi://book/<id>' -> book_key.
      //    Extract <id>, JOIN map. Rows whose uid doesn't map are dropped
      //    (orphan audiobooks — their epub is gone; v12 already pruned cues).
      if (await _columnExists('audiobooks', 'book_uid')) {
        await customStatement('''
        CREATE TABLE audiobooks_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL UNIQUE,
          audio_root TEXT,
          audio_paths_json TEXT,
          alignment_format TEXT NOT NULL,
          alignment_path TEXT NOT NULL,
          health_kind_raw TEXT,
          match_rate_pct INTEGER,
          health_measured_at INTEGER,
          health_reason TEXT,
          follow_audio INTEGER)''');
        await customStatement('''
        INSERT INTO audiobooks_new
          (id, book_key, audio_root, audio_paths_json, alignment_format,
           alignment_path, health_kind_raw, match_rate_pct, health_measured_at,
           health_reason, follow_audio)
        SELECT ab.id, m.book_key, ab.audio_root, ab.audio_paths_json,
               ab.alignment_format, ab.alignment_path, ab.health_kind_raw,
               ab.match_rate_pct, ab.health_measured_at, ab.health_reason,
               ab.follow_audio
        FROM audiobooks ab
        JOIN _id_key_map m
          ON m.old_id = CAST(
               substr(ab.book_uid, ${_kLegacyUidPrefix.length + 1}) AS INTEGER)
        WHERE ab.book_uid LIKE '$_kLegacyUidPrefix%' ''');
        await customStatement('DROP TABLE audiobooks');
        await customStatement(
            'ALTER TABLE audiobooks_new RENAME TO audiobooks');
      }

      // 9. audio_cues: book_uid owns EITHER an audiobook uid OR an srt_books.uid.
      //    Rename column to book_key; translate ONLY the audiobook-uid rows
      //    ('reader_ttu/hoshi://book/<id>'), leaving srt uids untouched. Drop
      //    audiobook-uid cues whose id no longer maps (orphans).
      if (await _columnExists('audio_cues', 'book_uid')) {
        await customStatement('''
        CREATE TABLE audio_cues_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL,
          chapter_href TEXT NOT NULL,
          sentence_index INTEGER NOT NULL,
          text_fragment_id TEXT NOT NULL,
          cue_text TEXT NOT NULL,
          start_ms INTEGER NOT NULL,
          end_ms INTEGER NOT NULL,
          audio_file_index INTEGER NOT NULL)''');
        // 9a. non-audiobook-uid cues (srt-owned) carried over verbatim.
        await customStatement('''
        INSERT INTO audio_cues_new
          (id, book_key, chapter_href, sentence_index, text_fragment_id,
           cue_text, start_ms, end_ms, audio_file_index)
        SELECT ac.id, ac.book_uid, ac.chapter_href, ac.sentence_index,
               ac.text_fragment_id, ac.cue_text, ac.start_ms, ac.end_ms,
               ac.audio_file_index
        FROM audio_cues ac
        WHERE ac.book_uid NOT LIKE '$_kLegacyUidPrefix%' ''');
        // 9b. audiobook-uid cues translated through the map.
        await customStatement('''
        INSERT INTO audio_cues_new
          (id, book_key, chapter_href, sentence_index, text_fragment_id,
           cue_text, start_ms, end_ms, audio_file_index)
        SELECT ac.id, m.book_key, ac.chapter_href, ac.sentence_index,
               ac.text_fragment_id, ac.cue_text, ac.start_ms, ac.end_ms,
               ac.audio_file_index
        FROM audio_cues ac
        JOIN _id_key_map m
          ON m.old_id = CAST(
               substr(ac.book_uid, ${_kLegacyUidPrefix.length + 1}) AS INTEGER)
        WHERE ac.book_uid LIKE '$_kLegacyUidPrefix%' ''');
        await customStatement('DROP TABLE audio_cues');
        await customStatement(
            'ALTER TABLE audio_cues_new RENAME TO audio_cues');
      }

      // 10. book_profiles: book_uid PK 'reader_ttu/hoshi://book/<id>' -> book_key.
      if (await _columnExists('book_profiles', 'book_uid')) {
        await customStatement('''
        CREATE TABLE book_profiles_new (
          book_key TEXT NOT NULL PRIMARY KEY,
          profile_id INTEGER NOT NULL REFERENCES profiles (id) ON DELETE CASCADE)''');
        await customStatement('''
        INSERT INTO book_profiles_new (book_key, profile_id)
        SELECT m.book_key, bp.profile_id
        FROM book_profiles bp
        JOIN _id_key_map m
          ON m.old_id = CAST(
               substr(bp.book_uid, ${_kLegacyUidPrefix.length + 1}) AS INTEGER)
        WHERE bp.book_uid LIKE '$_kLegacyUidPrefix%' ''');
        await customStatement('DROP TABLE book_profiles');
        await customStatement(
            'ALTER TABLE book_profiles_new RENAME TO book_profiles');
      }

      // 11. media_items identifier/unique_key: hoshi://book/<id> -> /<key>.
      // media_items is a v1 baseline table (created only in onCreate), so a
      // synthetic/partial legacy seed that starts mid-ladder may lack it.
      const String kIdentPrefix = 'hoshi://book/';
      final List<QueryRow> items = await _tableExists('media_items')
          ? await customSelect(
              "SELECT id, media_identifier, unique_key FROM media_items "
              "WHERE media_identifier LIKE 'hoshi://book/%'",
            ).get()
          : const <QueryRow>[];
      for (final QueryRow it in items) {
        final String mid = it.read<String>('media_identifier');
        final int? oldId = int.tryParse(mid.substring(kIdentPrefix.length));
        final String? key = oldId == null ? null : idToKey[oldId];
        if (key == null) continue;
        await customStatement(
          'UPDATE media_items SET media_identifier = ?, unique_key = ? '
          'WHERE id = ?',
          <Object?>[
            '$kIdentPrefix$key',
            '$kIdentPrefix$key',
            it.read<int>('id'),
          ],
        );
      }

      // 12. preferences re-key (two audiobook_pos key spaces merge to one).
      await _migrateBookKeyPrefsV16(idToKey);

      // 13. reading_statistics: align bare title -> sanitized key, merging
      //     rows that collapse to the same (title, date_key).
      await _migrateReadingStatsTitlesV16();

      // 14. Recreate indexes under the new book_key column names.
      await _ensureIndexes();

      await customStatement('DROP TABLE _id_key_map');

      // 15. Integrity gate: any dangling FK relation means the re-key was
      //     lossy/wrong. Throw to roll back the whole transaction (FK checks
      //     are deferred while foreign_keys=OFF, so this runs them explicitly).
      final List<QueryRow> violations =
          await customSelect('PRAGMA foreign_key_check').get();
      if (violations.isNotEmpty) {
        throw StateError(
            'book-key migration left FK violations: ${violations.length}');
      }
    }
  }

  /// Re-keys all per-book preferences from int id / legacy uid to bookKey.
  /// The two audiobook_pos_ key spaces (int-style from SyncRepository and
  /// uid-style from AudiobookRepository's realtime writes) merge; on conflict
  /// the uid-style value wins (it is the live player write).
  Future<void> _migrateBookKeyPrefsV16(Map<int, String> idToKey) async {
    if (!await _tableExists('preferences')) return;
    final List<QueryRow> rows =
        await customSelect('SELECT key, value FROM preferences').get();

    // Resolved new key -> value, with a priority flag so uid-style audiobook_pos
    // wins over int-style on collision.
    final Map<String, String> resolved = <String, String>{};
    final Set<String> uidWonPos = <String>{};
    final Set<String> oldKeysToDelete = <String>{};

    // Prefixes whose suffix is the legacy uid string (reader_ttu/hoshi://book/<id>).
    const List<String> uidPrefixes = <String>[
      'audiobook_pos_',
      'audiobook_follow_',
      'audiobook_delay_',
      'audiobook_speed_',
      'audiobook_volume_',
      'audiobook_image_pause_',
      'audiobook_health_overlay_',
    ];

    String? mapUidSuffix(String suffix) {
      if (!suffix.startsWith(_kLegacyUidPrefix)) return null;
      final int? oldId =
          int.tryParse(suffix.substring(_kLegacyUidPrefix.length));
      if (oldId == null) return null;
      return idToKey[oldId];
    }

    for (final QueryRow r in rows) {
      final String key = r.read<String>('key');
      final String value = r.read<String>('value');

      // audiobook_pos_ has TWO suffix shapes: bare int (SyncRepository) or the
      // legacy uid (AudiobookRepository). Handle it explicitly so both merge.
      if (key.startsWith('audiobook_pos_')) {
        final String suffix = key.substring('audiobook_pos_'.length);
        String? newKeyKey;
        bool isUid = false;
        if (suffix.startsWith(_kLegacyUidPrefix)) {
          final String? bk = mapUidSuffix(suffix);
          if (bk != null) {
            newKeyKey = 'audiobook_pos_$bk';
            isUid = true;
          }
        } else {
          final int? oldId = int.tryParse(suffix);
          final String? bk = oldId == null ? null : idToKey[oldId];
          if (bk != null) newKeyKey = 'audiobook_pos_$bk';
        }
        if (newKeyKey != null) {
          oldKeysToDelete.add(key);
          if (isUid) {
            resolved[newKeyKey] = value;
            uidWonPos.add(newKeyKey);
          } else if (!uidWonPos.contains(newKeyKey)) {
            resolved[newKeyKey] = value;
          }
        }
        continue;
      }

      // bookmarks_<int> (BookmarkRepository / migrateLegacyBookmarkPreferences
      // normally consumes these into the table, but re-key any leftover).
      if (key.startsWith('bookmarks_')) {
        final String suffix = key.substring('bookmarks_'.length);
        final int? oldId = int.tryParse(suffix);
        final String? bk = oldId == null ? null : idToKey[oldId];
        if (bk != null) {
          oldKeysToDelete.add(key);
          resolved['bookmarks_$bk'] = value;
        }
        continue;
      }

      // Remaining uid-suffix prefixes.
      for (final String prefix in uidPrefixes) {
        if (prefix == 'audiobook_pos_') continue; // handled above
        if (!key.startsWith(prefix)) continue;
        final String suffix = key.substring(prefix.length);
        final String? bk = mapUidSuffix(suffix);
        if (bk != null) {
          oldKeysToDelete.add(key);
          resolved['$prefix$bk'] = value;
        }
        break;
      }
    }

    // Delete old keys first, then write resolved new keys (uid-priority applied).
    for (final String k in oldKeysToDelete) {
      await customStatement(
          'DELETE FROM preferences WHERE key = ?', <Object?>[k]);
    }
    for (final MapEntry<String, String> e in resolved.entries) {
      await customStatement(
        'INSERT INTO preferences (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        <Object?>[e.key, e.value],
      );
    }
  }

  /// Rewrites reading_statistics.title from the bare title to the sanitized
  /// bookKey domain so stats join the new identity. Rows that collapse to the
  /// same (sanitized title, date_key) are merged additively.
  ///
  /// CONTRACT / known follow-up: reading_statistics is keyed by `title`, not by
  /// a book id — same-title books have always shared a stats row, so merging
  /// here is a pre-existing property, not new behaviour introduced by this
  /// migration. After this step the stored title equals `_sanitizeBookKey(title)`
  /// (the bookKey domain), but runtime stats writes STILL use the bare title.
  /// Milestone 2 (the runtime-sweep pass) switches those writes to key by
  /// bookKey; until then a stale bare-title write would create a parallel row.
  /// That divergence is bounded and intentionally accepted for milestone 1 —
  /// milestone 2 aligns the two.
  Future<void> _migrateReadingStatsTitlesV16() async {
    if (!await _tableExists('reading_statistics')) return;
    final List<QueryRow> rows = await customSelect(
            'SELECT id, title, date_key, characters_read, reading_time_ms, '
            'last_statistic_modified FROM reading_statistics')
        .get();

    // Group target (sanitizedTitle, dateKey) -> accumulated values + the row id
    // we keep (smallest id) and the row ids we delete (merged away).
    final Map<String, _StatAccum> merged = <String, _StatAccum>{};
    for (final QueryRow r in rows) {
      final int id = r.read<int>('id');
      final String sanitized = _sanitizeBookKey(r.read<String>('title'));
      final String dateKey = r.read<String>('date_key');
      final String groupKey = '$sanitized\u0000$dateKey';
      final int chars = r.read<int>('characters_read');
      final int timeMs = r.read<int>('reading_time_ms');
      final int lastMod = r.read<int>('last_statistic_modified');
      final _StatAccum? acc = merged[groupKey];
      if (acc == null) {
        merged[groupKey] = _StatAccum(
          keepId: id,
          title: sanitized,
          chars: chars,
          timeMs: timeMs,
          lastMod: lastMod,
        );
      } else {
        acc.chars += chars;
        acc.timeMs += timeMs;
        if (lastMod > acc.lastMod) acc.lastMod = lastMod;
        acc.deleteIds.add(id);
      }
    }

    for (final _StatAccum acc in merged.values) {
      for (final int delId in acc.deleteIds) {
        await customStatement(
            'DELETE FROM reading_statistics WHERE id = ?', <Object?>[delId]);
      }
      await customStatement(
        'UPDATE reading_statistics SET title = ?, characters_read = ?, '
        'reading_time_ms = ?, last_statistic_modified = ? WHERE id = ?',
        <Object?>[
          acc.title,
          acc.chars,
          acc.timeMs,
          acc.lastMod,
          acc.keepId,
        ],
      );
    }
  }
}

/// Mutable accumulator for reading_statistics merge during v16 migration.
class _StatAccum {
  _StatAccum({
    required this.keepId,
    required this.title,
    required this.chars,
    required this.timeMs,
    required this.lastMod,
  });

  final int keepId;
  final String title;
  int chars;
  int timeMs;
  int lastMod;
  final List<int> deleteIds = <int>[];
}
