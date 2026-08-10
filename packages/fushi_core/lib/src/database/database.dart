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
import 'media_kind_mappings.dart';
import 'pref_codec.dart';
import 'sync_tombstone_kind.dart';
import 'tables.dart';
import 'tag_host_kind.dart';

part 'database.g.dart';
part 'database_infra.part.dart';
part 'database_prefs_media.part.dart';
part 'database_video_domain.part.dart';
part 'database_library.part.dart';
part 'database_statistics.part.dart';
part 'database_content_misc.part.dart';
part 'database_tags_sync.part.dart';

/// Thrown when the on-disk database was created by a NEWER build of Fushi than
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

void _requireOneVideoMetadataOwner({
  int? workId,
  int? seasonId,
  int? episodeId,
  String? personKey,
  String? characterKey,
}) {
  final int count = <Object?>[
    workId,
    seasonId,
    episodeId,
    personKey,
    characterKey,
  ].where((Object? value) => value != null).length;
  if (count != 1) {
    throw ArgumentError('exactly one video metadata owner is required');
  }
}

@DriftDatabase(tables: [
  MediaOpenHistory,
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
  TagAssignments,
  Profiles,
  ProfileSettings,
  MediaTypeProfiles,
  BookProfiles,
  SyncBaselines,
  VideoBooks,
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
  MangaExtensionStores,
  MangaExtensions,
  MangaOnlineSources,
  MangaSourcePreferences,
  MangaTrustedSigners,
  CollectionRelations,
  MediaImages,
  VideoMetadataWorks,
  VideoMetadataSeasons,
  VideoMetadataEpisodes,
  VideoMetadataPeople,
  VideoMetadataCharacters,
  VideoMetadataProviderIdentities,
  VideoMetadataRawSnapshots,
  VideoMetadataTerms,
  VideoMetadataWorkTerms,
  VideoMetadataCredits,
  VideoMetadataImages,
  VideoMetadataExtras,
  VideoSourceScrapeSettings,
  VideoSourceScrapeRuns,
  VideoSidecarArtifacts,
  VideoDownloadJobs,
  VideoDownloadJobFiles,
  VideoDownloadJobSubtitles,
  VideoDownloadSubscriptions,
  VideoDownloadSubscriptionItems,
])
class FushiDatabase extends _$FushiDatabase
    with
        _FushiDbInfra,
        _FushiDbTagsSync,
        _FushiDbLibrary,
        _FushiDbPrefsMedia,
        _FushiDbContentMisc,
        _FushiDbStatistics,
        _FushiDbVideoDomain {
  /// [isMainProcess] gates the TODO-905 sidecar rebuild: the main app passes
  /// the default `true` (it may physically delete a poisoned `-wal`/`-shm`),
  /// while the separate `:popup` process passes `false` so it backs off on an
  /// IOERR instead of racing the main process to delete the same sidecar.
  FushiDatabase(String dbDirectory, {bool isMainProcess = true})
      : _isMainProcess = isMainProcess,
        super(_openDb(dbDirectory, isMainProcess: isMainProcess));

  /// Opens a specific `.db` FILE (not a directory). Backup MERGE import
  /// (TODO-888) uses this to migrate an extracted backup DB to the current
  /// schema before merging it into the live DB.
  FushiDatabase.atFile(String dbFilePath, {bool isMainProcess = true})
      : _isMainProcess = isMainProcess,
        super(_openDbFile(dbFilePath, isMainProcess: isMainProcess));

  FushiDatabase.forTesting(super.e) : _isMainProcess = true;

  final bool _isMainProcess;

  @override
  int get schemaVersion => 83;

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
            // v77 起 book_tag_mappings 并入 tag_assignments，Dart 表类已删；
            // 本阶梯步冻结为当年 m.createTable 生成的 SQL 原文（此表在 v77 步
            // 被整体搬移后 DROP）。
            await customStatement(
                'CREATE TABLE IF NOT EXISTS "book_tag_mappings" ('
                '"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
                '"book_key" TEXT NOT NULL REFERENCES epub_books (book_key) ON DELETE CASCADE, '
                '"tag_id" INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE, '
                '"added_at" INTEGER NOT NULL DEFAULT 0, '
                'UNIQUE ("book_key", "tag_id"))');
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
            // v77 冻结（同 book_tag_mappings 处说明）。
            await customStatement(
                'CREATE TABLE IF NOT EXISTS "srt_book_tag_mappings" ('
                '"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
                '"srt_book_id" INTEGER NOT NULL REFERENCES srt_books (id) ON DELETE CASCADE, '
                '"tag_id" INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE, '
                'UNIQUE ("srt_book_id", "tag_id"))');
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
              // v77 冻结（同 book_tag_mappings 处说明）。注意此步创建的是 v57
              // 改名后的现名列 book_uid——与原 m.createTable(当前 Dart 定义) 行为
              // 一致（阶梯步从来就是建当前形，守卫测试认可）。
              await customStatement(
                  'CREATE TABLE IF NOT EXISTS "video_book_tag_mappings" ('
                  '"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
                  '"book_uid" TEXT NOT NULL REFERENCES video_books (book_uid) ON DELETE CASCADE, '
                  '"tag_id" INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE, '
                  '"added_at" INTEGER NOT NULL DEFAULT 0, '
                  'UNIQUE ("book_uid", "tag_id"))');
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
            // （v77 冻结：两表的 Dart 类已删，addColumn 改等价裸 SQL。）
            if (await _tableExists('book_tag_mappings') &&
                !await _columnExists('book_tag_mappings', 'added_at')) {
              await customStatement('ALTER TABLE book_tag_mappings '
                  'ADD COLUMN added_at INTEGER NOT NULL DEFAULT 0');
            }
            if (await _tableExists('video_book_tag_mappings') &&
                !await _columnExists('video_book_tag_mappings', 'added_at')) {
              await customStatement('ALTER TABLE video_book_tag_mappings '
                  'ADD COLUMN added_at INTEGER NOT NULL DEFAULT 0');
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
              // v77 冻结（同 book_tag_mappings 处说明）。
              await customStatement(
                  'CREATE TABLE IF NOT EXISTS "collection_tag_mappings" ('
                  '"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
                  '"collection_id" INTEGER NOT NULL REFERENCES media_collections (id) ON DELETE CASCADE, '
                  '"tag_id" INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE, '
                  'UNIQUE ("collection_id", "tag_id"))');
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
                // v77 冻结：表类已删，原 TableMigration(columnTransformer) 是
                // 单列改名，等价 RENAME COLUMN（SQLite ≥3.25；本表 v77 步终将
                // 整体搬移后 DROP，中间形只需列名对齐）。
                await customStatement('ALTER TABLE video_book_tag_mappings '
                    'RENAME COLUMN video_book_uid TO book_uid');
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
              // v77 冻结（同 book_tag_mappings 处说明）。
              await customStatement(
                  'CREATE TABLE IF NOT EXISTS "galgame_tag_mappings" ('
                  '"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
                  '"game_id" TEXT NOT NULL REFERENCES galgames (id) ON DELETE CASCADE, '
                  '"tag_id" INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE, '
                  'UNIQUE ("game_id", "tag_id"))');
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
          if (from < 70) {
            // v70（Fushi 终局清算 W2-1）：阅读器源持久化键 'reader_ttu' →
            // 'reader_fushi'，连带 pref shortKey 的死前缀 'ttu_' 剥除（命名空间段
            // 已写明 reader，shortKey 再带 ttu_ 是纯冗余）。旧字面量此后只允许
            // 活在本迁移步与 v16 阶梯（_kLegacyUidPrefix 族）里。
            //
            // 落库位共三处（W2 盘点结论，tables.dart 逐表核对）：
            //  1. preferences.key —— `src:reader_ttu:<shortKey>` 命名空间 +
            //     BUG-1317 前的 legacy override_title 键内嵌双源键段
            //     `override_title://reader_ttu/reader_ttu/<mediaId>`；
            //  2. profile_settings.key —— category='pref' 行存整串 pref key
            //     （同 1 的两种形态），category='reader' 旧快照行存裸 shortKey；
            //  3. media_items —— media_source_identifier = 'reader_ttu' 与
            //     unique_key 前缀 `reader_ttu/<mediaId>`。
            // 其余表（shelf/stats/collections/mined 等）存裸 bookKey 或
            // mediaType 值域，不含源键，刻意不动。
            //
            // 顺序敏感：先换命名空间段，再改写换名后键里的 legacy override 内嵌
            // 段，最后剥 shortKey 前缀。UPDATE OR REPLACE：preferences.key 是主键
            // （media_items.unique_key 是 UNIQUE），真实旧库不可能同时存在新旧两
            // 形态（新命名空间从未被旧版本写过），但半合成库里撞上时保留改写结果
            // 而不是让整条 onUpgrade 中断（= 库打不开）。幂等由 from<70 门槛保证；
            // 语句本身也天然幂等（改写后无旧前缀行可匹配）。
            const String oldNs = 'src:reader_ttu:';
            const String newNs = 'src:reader_fushi:';
            const String oldLegacyOverride =
                'src:reader_fushi:override_title://reader_ttu/reader_ttu/';
            const String newLegacyOverride =
                'src:reader_fushi:override_title://reader_fushi/reader_fushi/';
            const String oldShort = 'src:reader_fushi:ttu_';
            for (final String table in <String>[
              'preferences',
              'profile_settings',
            ]) {
              if (!await _tableExists(table)) continue;
              await _rewriteTextPrefix(
                  table: table, column: 'key', from: oldNs, to: newNs);
              await _rewriteTextPrefix(
                  table: table,
                  column: 'key',
                  from: oldLegacyOverride,
                  to: newLegacyOverride);
              await _rewriteTextPrefix(
                  table: table, column: 'key', from: oldShort, to: newNs);
            }
            if (await _tableExists('profile_settings')) {
              // 旧 'reader' 类别快照行存裸 shortKey（无命名空间），单独剥前缀。
              await _rewriteTextPrefix(
                  table: 'profile_settings',
                  column: 'key',
                  from: 'ttu_',
                  to: '',
                  extraWhere: "category = 'reader'");
            }
            // current_source/<mediaType> 偏好把源 uniqueKey 当**值**存：
            // 新写入是 PrefCodec 标签形态 's:reader_ttu'，历史裸写是
            // 'reader_ttu'，两种都改写（不动其它值恰为该串的无关键）。
            for (final String table in <String>[
              'preferences',
              'profile_settings',
            ]) {
              if (!await _tableExists(table)) continue;
              await customStatement(
                  "UPDATE $table SET value = 's:reader_fushi' "
                  "WHERE key LIKE 'current\\_source/%' ESCAPE '\\' "
                  "AND value = 's:reader_ttu'");
              await customStatement("UPDATE $table SET value = 'reader_fushi' "
                  "WHERE key LIKE 'current\\_source/%' ESCAPE '\\' "
                  "AND value = 'reader_ttu'");
            }
            if (await _tableExists('media_items')) {
              await customStatement('UPDATE OR REPLACE media_items '
                  "SET media_source_identifier = 'reader_fushi' "
                  "WHERE media_source_identifier = 'reader_ttu'");
              await _rewriteTextPrefix(
                  table: 'media_items',
                  column: 'unique_key',
                  from: 'reader_ttu/',
                  to: 'reader_fushi/');
            }
          }
          if (from < 71) {
            // v71（Fushi 终局清算 W2-2）：sasayaki 族存量持久化值一次性改写。
            // 三个落库位（W2 盘点结论）：
            //  1. audio_cues.text_fragment_id —— 字幕重匹配命中编码的 scheme
            //     前缀 `sasayaki://` → `fushi-cue://`（SubtitleRematchCodec）；
            //  2. preferences/profile_settings 的 custom_themes 值 —— 自定义
            //     主题条目 JSON 里的 'sasayakiColor' 键 →
            //     'sentenceAudioHighlightColor'（值是 PrefCodec 编码的
            //     List<String>，条目引号被转义，故用裸词 REPLACE；该词撞上
            //     用户主题名的概率可忽略，且主题分享码不含此键——'sk' 段）；
            //  3. preferences/profile_settings 的偏好键
            //     custom_theme_sasayaki_color → custom_theme_sentence_audio_color
            //     （精确匹配整键；OR REPLACE 防半合成库新旧并存撞主键）。
            // {sasayaki-audio} handlebars 别名存在 SharedPreferences（非本库），
            // 由 BaseAnkiRepository 载入期迁移改写，刻意不在此步。
            if (await _tableExists('audio_cues')) {
              await _rewriteTextPrefix(
                  table: 'audio_cues',
                  column: 'text_fragment_id',
                  from: 'sasayaki://',
                  to: 'fushi-cue://');
            }
            for (final String table in <String>[
              'preferences',
              'profile_settings',
            ]) {
              if (!await _tableExists(table)) continue;
              await customStatement('UPDATE $table '
                  "SET value = REPLACE(value, 'sasayakiColor', "
                  "'sentenceAudioHighlightColor') "
                  "WHERE key = 'custom_themes' "
                  "AND value LIKE '%sasayakiColor%'");
              await customStatement('UPDATE OR REPLACE $table '
                  "SET key = 'custom_theme_sentence_audio_color' "
                  "WHERE key = 'custom_theme_sasayaki_color'");
            }
          }
          if (from < 72) {
            // v72（Fushi 终局清算 W2-7）：书库目录名 hoshi_books → fushi_books
            // 的库内路径改写 + 已删功能残留偏好清理。磁盘目录本体由 app 启动期
            // 在**开库前**就地改名（books_directory.dart），本步与之同一启动内
            // 生效。REPLACE 是逐字面替换；WHERE LIKE 只是过滤优化（`_` 通配符
            // 带来的伪命中行会被 REPLACE no-op，无害，刻意不 ESCAPE）。
            //  1. epub_books.extract_dir —— `<documents>/hoshi_books/<bookKey>`
            //     绝对路径（epub/manga/pdf 三种书共用一列）；Windows 反斜杠与
            //     POSIX 正斜杠两种分隔符形态都改。
            //  2. media_items.image_url —— 本地书封面 file:// URI（恒正斜杠，
            //     目录名是纯 ASCII 不会被百分号编码）。
            //  3. google_drive_hoshi_compat —— Hoshi 共享空间功能已删（云同步
            //     改名批），键已无任何读写方，残留行直接清掉（preferences +
            //     profile_settings 快照），不搬空值。
            if (await _tableExists('epub_books')) {
              await customStatement('UPDATE epub_books SET extract_dir = '
                  "REPLACE(extract_dir, '/hoshi_books/', '/fushi_books/') "
                  "WHERE extract_dir LIKE '%/hoshi_books/%'");
              await customStatement('UPDATE epub_books SET extract_dir = '
                  "REPLACE(extract_dir, '\\hoshi_books\\', '\\fushi_books\\') "
                  "WHERE extract_dir LIKE '%\\hoshi_books\\%'");
            }
            if (await _tableExists('media_items')) {
              await customStatement('UPDATE media_items SET image_url = '
                  "REPLACE(image_url, '/hoshi_books/', '/fushi_books/') "
                  'WHERE image_url IS NOT NULL '
                  "AND image_url LIKE '%/hoshi_books/%'");
            }
            for (final String table in <String>[
              'preferences',
              'profile_settings',
            ]) {
              if (!await _tableExists(table)) continue;
              await customStatement('DELETE FROM $table '
                  "WHERE key = 'google_drive_hoshi_compat'");
            }
          }
          if (from < 73) {
            // v73（Fushi 终局清算 W2-3）：mediaIdentifier scheme 前缀
            // `hoshi://book/` / `hoshi://srtbook/` → `fushi://book/` /
            // `fushi://srtbook/` 的存量行改写。落库位（W2 盘点，tables.dart
            // 全表核对）：
            //  1. media_items.media_identifier —— 裸前缀形态；
            //  2. media_items.unique_key —— `<源键>/<mediaId>` 复合形态：只换
            //     URI 段（REPLACE 带 `/` 左锚），**保留源键段**（v16 的
            //     audiobook uid 迁移丢过源前缀，别抄那个骨架）；
            //  3. preferences / profile_settings 的 override_title 键——规范
            //     `override_title://<mediaId>` 与 BUG-1317 前的 legacy
            //     `override_title://<src>/<src>/<mediaId>` 两形态，URI 段一并
            //     改写（UPDATE OR REPLACE 防半合成库新旧并存撞主键）。
            // 其余表存裸 bookKey / SrtBook.uid，无 scheme 前缀，刻意不动。
            // override 封面的 hashCode 派生**文件名**在磁盘不在库，由 app 启动
            // 期 override_thumbnail_migration.dart 一次性清扫。
            if (await _tableExists('media_items')) {
              for (final List<String> pair in <List<String>>[
                <String>['hoshi://book/', 'fushi://book/'],
                <String>['hoshi://srtbook/', 'fushi://srtbook/'],
              ]) {
                await _rewriteTextPrefix(
                    table: 'media_items',
                    column: 'media_identifier',
                    from: pair[0],
                    to: pair[1]);
                await customStatement('UPDATE OR REPLACE media_items '
                    "SET unique_key = REPLACE(unique_key, '/${pair[0]}', "
                    "'/${pair[1]}') "
                    "WHERE unique_key LIKE '%/${pair[0]}%'");
                // v16 阶梯给 v15 时代旧库写出的 unique_key 是**裸**
                // `hoshi://book/<key>`（无源键段）——上面带 `/` 左锚的 REPLACE
                // 够不着它，会留下 media_identifier 已新、unique_key 还旧的
                // 两列不一致。前缀锚定改写补齐（复合形态左起是源键、不会被
                // 此前缀命中，两条互不重叠）。
                await _rewriteTextPrefix(
                    table: 'media_items',
                    column: 'unique_key',
                    from: pair[0],
                    to: pair[1]);
              }
            }
            for (final String table in <String>[
              'preferences',
              'profile_settings',
            ]) {
              if (!await _tableExists(table)) continue;
              await customStatement('UPDATE OR REPLACE $table SET key = '
                  "REPLACE(REPLACE(key, 'hoshi://book/', 'fushi://book/'), "
                  "'hoshi://srtbook/', 'fushi://srtbook/') "
                  "WHERE key LIKE '%override\\_title://%' ESCAPE '\\' "
                  "AND (key LIKE '%hoshi://book/%' "
                  "OR key LIKE '%hoshi://srtbook/%')");
            }
          }
          if (from < 74) {
            // v74（W9-6）：SyncBackendType 枚举值 hibikiServer → fushiServer 的
            // 存量改写。落库位只有 sync_backend_type 一个键，值形态是 drift 偏好
            // 的字符串前缀编码 `s:<enum name>`（见 SyncRepository._keyBackendType）。
            // 不改的话：用户「同步方式＝互联」的选择在新版读不出来，
            // resolveSyncBackend 落回默认后端 = 静默把互联关掉。
            // profile_settings 一并扫：偏好在两处都可能有每 Profile 快照。
            for (final String table in <String>[
              'preferences',
              'profile_settings',
            ]) {
              if (!await _tableExists(table)) continue;
              await customStatement('UPDATE $table '
                  "SET value = 's:fushiServer' "
                  "WHERE key = 'sync_backend_type' "
                  "AND value = 's:hibikiServer'");
            }
          }
          if (from < 75) {
            // v75（每游戏日语区域档位，BUG-1477）：galgames 加 japanese_locale_mode
            // 列，存 'auto' / 'on' / 'off'。与 v62 的 upscaling_mode、v56 的
            // launch_args 同型：都是「用户为该游戏设的启动期配置」。
            //
            // 无损迁移：列带 DEFAULT ''，SQLite ADD COLUMN 把既有全部行回填空串。
            // 注意空串在解析层回落的是 **auto** 而不是 off——转区是用户明确要过的
            // 功能（BUG-1038），加了开关就把老用户默默关掉才是破坏用户空间。
            // 守卫幂等（fresh DB 已由 onCreate 的 createAll 建好，重复升级
            // _columnExists 短路 no-op）。
            if (await _tableExists('galgames') &&
                !await _columnExists('galgames', 'japanese_locale_mode')) {
              await m.addColumn(galgames, galgames.japaneseLocaleMode);
            }
          }
          if (from < 76) {
            // v76（v39 的另一半）：lookup_mining_counters 的 book_key 进唯一键，
            // 根治同名不同视频的查词/制卡计数互串（旧唯一键 {title,source_type,
            // date_key} 不含身份，addLookupCount/addMineCountPerBook 匹配现有行时
            // 忽略 bookKey → 同名视频合进同一行）。三步：
            // ① NULL → ''（新列定义 NOT NULL DEFAULT ''；先归一再重建，避免
            //    TableMigration 拷贝时违反非空约束）；
            // ② alterTable 按当前 Dart 定义重建（唯一键换 {title,source_type,
            //    date_key,book_key}，title 打头保三列前缀查询的索引——新键是旧键
            //    超集，既有行必仍唯一，重建不可能撞约束）；
            // ③ 按 title 唯一匹配回填身份（v39 同判据、同 SQL 形状）：book 行
            //    JOIN epub_books、video 行 JOIN video_books；同名多条目/无匹配
            //    保持 ''（读取端按 title 回退归并，见 stat_shared 的身份分组）。
            // 回填用库表 JOIN 而非重算派生函数：sanitizeTtuFilename 在 app 层，
            // fushi_core 不该复制一份实现出双真相源。
            if (await _tableExists('lookup_mining_counters')) {
              await customStatement(
                  'UPDATE lookup_mining_counters SET book_key = '
                  "''"
                  ' WHERE book_key IS NULL');
              await m.alterTable(TableMigration(lookupMiningCounters));
              if (await _tableExists('epub_books')) {
                await customStatement(
                  'UPDATE lookup_mining_counters SET book_key = COALESCE(('
                  ' SELECT eb.book_key FROM epub_books eb'
                  ' WHERE eb.title = lookup_mining_counters.title'
                  ' AND NOT EXISTS (SELECT 1 FROM epub_books eb2'
                  '  WHERE eb2.title = eb.title'
                  '  AND eb2.book_key != eb.book_key)'
                  "), '') WHERE book_key = '' AND title != ''"
                  " AND source_type = 'book'",
                );
              }
              if (await _tableExists('video_books')) {
                await customStatement(
                  'UPDATE lookup_mining_counters SET book_key = COALESCE(('
                  ' SELECT vb.book_uid FROM video_books vb'
                  ' WHERE vb.title = lookup_mining_counters.title'
                  ' AND NOT EXISTS (SELECT 1 FROM video_books vb2'
                  '  WHERE vb2.title = vb.title'
                  '  AND vb2.book_uid != vb.book_uid)'
                  "), '') WHERE book_key = '' AND title != ''"
                  " AND source_type = 'video'",
                );
              }
            }
          }
          if (from < 77) {
            // v77：视频来源规范刮削与 NFO sidecar 的结构化宿主（PR #792，
            // 开发期编号 v69/v70 两步在合入 develop 时收拢为一步）。全部是
            // 可重建缓存/任务审计表，不改写既有视频、合集、进度或兼容刮削
            // 资料：旧库升级后新表为空，既有行为逐像素不变；第一次来源刮削
            // 再逐步回填。
            //
            // 建表顺序严格按 FK 父子关系排列。每张表独立存在性守卫既允许完整旧库
            // 升级，也允许开发期中断后重试，不会重复建表或清掉已成功写入的数据。
            if (!await _tableExists('video_metadata_works')) {
              await m.createTable(videoMetadataWorks);
            }
            if (!await _tableExists('video_metadata_seasons')) {
              await m.createTable(videoMetadataSeasons);
            }
            if (!await _tableExists('video_metadata_episodes')) {
              await m.createTable(videoMetadataEpisodes);
            }
            if (!await _tableExists('video_metadata_people')) {
              await m.createTable(videoMetadataPeople);
            }
            if (!await _tableExists('video_metadata_characters')) {
              await m.createTable(videoMetadataCharacters);
            }
            if (!await _tableExists('video_metadata_provider_identities')) {
              await m.createTable(videoMetadataProviderIdentities);
            }
            if (!await _tableExists('video_metadata_raw_snapshots')) {
              await m.createTable(videoMetadataRawSnapshots);
            }
            if (!await _tableExists('video_metadata_terms')) {
              await m.createTable(videoMetadataTerms);
            }
            if (!await _tableExists('video_metadata_work_terms')) {
              await m.createTable(videoMetadataWorkTerms);
            }
            if (!await _tableExists('video_metadata_credits')) {
              await m.createTable(videoMetadataCredits);
            }
            if (!await _tableExists('video_metadata_images')) {
              await m.createTable(videoMetadataImages);
            }
            if (!await _tableExists('video_metadata_extras')) {
              await m.createTable(videoMetadataExtras);
            }
            if (!await _tableExists('video_source_scrape_settings')) {
              await m.createTable(videoSourceScrapeSettings);
            }
            if (!await _tableExists('video_source_scrape_runs')) {
              await m.createTable(videoSourceScrapeRuns);
            }
            if (!await _tableExists('video_sidecar_artifacts')) {
              await m.createTable(videoSidecarArtifacts);
            }
            await _ensureIndexes();
          }
          if (from < 78) {
            // v78：通用视频下载/订阅持久层（PR #794 增量，收拢为一步迁移；
            // 上游 fork 编号 v71）。建表顺序严格遵循 FK：任务父表 →
            // 文件 → 字幕、订阅父表 → 订阅条目。旧的 JSON 计划由 app 层一次性导入，
            // 本迁移只建立空真相源，不猜磁盘文件语义，也不改变既有下载行为。
            if (!await _tableExists('video_download_jobs')) {
              await m.createTable(videoDownloadJobs);
            }
            if (!await _tableExists('video_download_job_files')) {
              await m.createTable(videoDownloadJobFiles);
            }
            if (!await _tableExists('video_download_job_subtitles')) {
              await m.createTable(videoDownloadJobSubtitles);
            }
            if (!await _tableExists('video_download_subscriptions')) {
              await m.createTable(videoDownloadSubscriptions);
            }
            if (!await _tableExists('video_download_subscription_items')) {
              await m.createTable(videoDownloadSubscriptionItems);
            }
            await _ensureIndexes();
          }
          if (from < 79) {
            // v79（五张标签映射表合一，2026-08 数据层重构·用户拍板）：
            // book/srt/video/collection/galgame *_tag_mappings → tag_assignments
            // （统一 (media_kind, entry_key, tag_id, added_at)，设计取舍见
            // tables.dart 的 [TagAssignments] doc）。逐表搬移后 DROP：
            //  - epub/video：entry_key 与 added_at 原样平移；
            //  - srt：弃本机自增 int id，JOIN srt_books 换跨设备稳定的 uid
            //    （孤儿映射行 JOIN 天然丢弃）；
            //  - collection：id 字符串化；game：id 原样。三者旧表无 added_at，
            //    落 0（最古 add，同 v41 给 book/video 补列的语义）。
            // INSERT OR IGNORE 防 PK 撞（正常数据不会撞，防御性幂等）；每路
            // SELECT 都带 tag_id IN (SELECT id FROM book_tags) 过滤——迁移在
            // PRAGMA foreign_keys=ON 下跑，OR IGNORE 压不住 FK 违规，pre-v10
            // FK-off 时代的悬空 tag_id（v10 曾专门清理过，野库确有）会把升级
            // 整个 abort（review5-2）。悬空行本就指向不存在的标签，丢弃即正确。
            // 守卫幂等：fresh DB 走 onCreate（无旧表，全部 _tableExists 短路）。
            if (!await _tableExists('tag_assignments')) {
              await m.createTable(tagAssignments);
            }
            // 极老/极简库可能连 book_tags 都没有（v1 基线表只在 onCreate 建）：
            // 没有标签定义表就不可能有有效映射，跳过搬移只做 DROP；tag_assignments
            // 的 tag_id FK 在 INSERT 时要解析父表，缺表会直接抛。
            final bool hasBookTags = await _tableExists('book_tags');
            if (hasBookTags && await _tableExists('book_tag_mappings')) {
              await customStatement('INSERT OR IGNORE INTO tag_assignments '
                  '(media_kind, entry_key, tag_id, added_at) '
                  "SELECT 'epub', book_key, tag_id, added_at "
                  'FROM book_tag_mappings '
                  'WHERE tag_id IN (SELECT id FROM book_tags)');
              await customStatement('DROP TABLE book_tag_mappings');
            }
            if (hasBookTags && await _tableExists('srt_book_tag_mappings')) {
              // uid 换键要 JOIN srt_books（v1 基线表，极简合成库可能没有——
              // 没有宿主表映射就不可解析，跳过搬移只 DROP）。
              if (await _tableExists('srt_books')) {
                await customStatement('INSERT OR IGNORE INTO tag_assignments '
                    '(media_kind, entry_key, tag_id, added_at) '
                    "SELECT 'srt', sb.uid, sm.tag_id, 0 "
                    'FROM srt_book_tag_mappings sm '
                    'JOIN srt_books sb ON sb.id = sm.srt_book_id '
                    'WHERE sm.tag_id IN (SELECT id FROM book_tags)');
              }
              await customStatement('DROP TABLE srt_book_tag_mappings');
            }
            if (hasBookTags && await _tableExists('video_book_tag_mappings')) {
              await customStatement('INSERT OR IGNORE INTO tag_assignments '
                  '(media_kind, entry_key, tag_id, added_at) '
                  "SELECT 'video', book_uid, tag_id, added_at "
                  'FROM video_book_tag_mappings '
                  'WHERE tag_id IN (SELECT id FROM book_tags)');
              await customStatement('DROP TABLE video_book_tag_mappings');
            }
            if (hasBookTags && await _tableExists('collection_tag_mappings')) {
              await customStatement('INSERT OR IGNORE INTO tag_assignments '
                  '(media_kind, entry_key, tag_id, added_at) '
                  "SELECT 'collection', CAST(collection_id AS TEXT), tag_id, 0 "
                  'FROM collection_tag_mappings '
                  'WHERE tag_id IN (SELECT id FROM book_tags)');
              await customStatement('DROP TABLE collection_tag_mappings');
            }
            if (hasBookTags && await _tableExists('galgame_tag_mappings')) {
              await customStatement('INSERT OR IGNORE INTO tag_assignments '
                  '(media_kind, entry_key, tag_id, added_at) '
                  "SELECT 'game', game_id, tag_id, 0 "
                  'FROM galgame_tag_mappings '
                  'WHERE tag_id IN (SELECT id FROM book_tags)');
              await customStatement('DROP TABLE galgame_tag_mappings');
            }
            // 升级路径也要拿到 idx_tag_assignments_tag_id（_ensureIndexes 平时
            // 只在 onCreate 与 v14 步跑，老库升级会漏；幂等，from<48 步先例。
            // review5-5）。
            await _ensureIndexes();
            if (!hasBookTags) {
              for (final String legacy in <String>[
                'book_tag_mappings',
                'srt_book_tag_mappings',
                'video_book_tag_mappings',
                'collection_tag_mappings',
                'galgame_tag_mappings',
              ]) {
                if (await _tableExists(legacy)) {
                  await customStatement('DROP TABLE ' + legacy);
                }
              }
            }
          }
          if (from < 80) {
            // v80（media_items → media_open_history，2026-08 数据层重构·用户令
            // 弃 jidoujisho 血统重设计）：19 列摊平的旧最近打开表收敛为
            // 身份 (media_source, media_id) + opened_at + 进度两列 + snapshot
            // JSON（title/封面/URL/作者/extra 等展示与重开载荷）。逐行 Dart 搬移
            // （行数被 trim 钉在每类型 ≤100，循环无量级问题）；遗留 base64 图片
            // 原样进 snapshot（无活写入方，随行被 trim 自然消亡）。旧表 DROP。
            if (!await _tableExists('media_open_history')) {
              await m.createTable(mediaOpenHistory);
            }
            if (await _tableExists('media_items')) {
              final List<QueryRow> legacyRows = await customSelect(
                'SELECT media_identifier, title, media_type_identifier, '
                'media_source_identifier, base64_image, image_url, audio_url, '
                'author, author_identifier, extra_url, extra, source_metadata, '
                'position, duration, imported_at FROM media_items',
              ).get();
              for (final QueryRow r in legacyRows) {
                final Map<String, Object?> snapshot = <String, Object?>{
                  'title': r.read<String>('title'),
                  if (r.read<String?>('base64_image') case final String v)
                    'base64Image': v,
                  if (r.read<String?>('image_url') case final String v)
                    'imageUrl': v,
                  if (r.read<String?>('audio_url') case final String v)
                    'audioUrl': v,
                  if (r.read<String?>('author') case final String v)
                    'author': v,
                  if (r.read<String?>('author_identifier') case final String v)
                    'authorIdentifier': v,
                  if (r.read<String?>('extra_url') case final String v)
                    'extraUrl': v,
                  if (r.read<String?>('extra') case final String v) 'extra': v,
                  if (r.read<String?>('source_metadata') case final String v)
                    'sourceMetadata': v,
                };
                await customStatement(
                  'INSERT OR REPLACE INTO media_open_history '
                  '(media_type, media_source, media_id, opened_at, position, '
                  'duration, snapshot_json) VALUES (?, ?, ?, ?, ?, ?, ?)',
                  <Object?>[
                    r.read<String>('media_type_identifier'),
                    r.read<String>('media_source_identifier'),
                    r.read<String>('media_identifier'),
                    r.read<int>('imported_at'),
                    r.read<int>('position'),
                    r.read<int>('duration'),
                    jsonEncode(snapshot),
                  ],
                );
              }
              await customStatement('DROP TABLE media_items');
            }
          }
          if (from < 81) {
            // v81（P3 Stage 1：书身份地基）：epub_books 加本机稳定 uid 列。
            // 存量回填 `book_<rowid>_<epoch>`——rowid 保批内唯一，与导入路径
            // 的 [generateEpubBookUid]（时刻+计数器）同一命名空间不同后缀形，
            // 不可能撞。回填后建独立唯一索引（ADD COLUMN 不能带 UNIQUE；这条
            // 索引也刻意**不进 _ensureIndexes** ——那个清单会被更早的迁移步
            // 调用，彼时列还不存在会当场崩，见 onCreate 侧的成对内联）。
            if (await _tableExists('epub_books')) {
              if (!await _columnExists('epub_books', 'uid')) {
                await customStatement(
                    "ALTER TABLE epub_books ADD COLUMN uid TEXT NOT NULL "
                    "DEFAULT ''");
                await customStatement(
                    "UPDATE epub_books SET uid = 'book_' || rowid || '_' || "
                    "strftime('%s','now') WHERE uid = ''");
              }
              await customStatement(
                  'CREATE UNIQUE INDEX IF NOT EXISTS idx_epub_books_uid '
                  "ON epub_books (uid) WHERE uid != ''");
            }
          }
          if (from < 82) {
            // v82（P3 Stage 1b）：四张子表书键从 book_key(=sanitize(title))
            // 切到本机稳定 uid（v81 地基）。create-copy-drop-rename（v24 同形，
            // 裸 SQL 保证与 drift 生成形一致）：
            // - reader_positions 跨书族：epub 命中换 uid，JOIN 不上的行（SRT
            //   等非 epub 域）照抄原键值（该域键本就稳定）；
            // - bookmarks / book_custom_css / revealed_images 纯 epub 域：
            //   INNER JOIN 顺带清孤儿（css 历史无 FK 会积孤儿行）。
            // 列级重入守卫：book_key 列还在才重建（v82 后建的库/已迁完直接跳过）。
            // epub_books 守卫与阶梯其它触碰步同风格（合成/partial 测试库防炸；
            // 真实阶梯库 from<5 必建 epub_books）。
            final bool hasEpubBooks = await _tableExists('epub_books');
            if (hasEpubBooks &&
                await _tableExists('reader_positions') &&
                await _columnExists('reader_positions', 'book_key')) {
              await customStatement('''
              CREATE TABLE reader_positions_v82 (
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                book_uid TEXT NOT NULL UNIQUE,
                section_index INTEGER NOT NULL,
                norm_char_offset INTEGER NOT NULL,
                char_offset INTEGER NOT NULL DEFAULT -1,
                updated_at INTEGER NOT NULL)''');
              await customStatement('''
              INSERT INTO reader_positions_v82
                (id, book_uid, section_index, norm_char_offset, char_offset,
                 updated_at)
              SELECT rp.id,
                     COALESCE((SELECT eb.uid FROM epub_books eb
                               WHERE eb.book_key = rp.book_key
                                 AND eb.uid != ''),
                              rp.book_key),
                     rp.section_index, rp.norm_char_offset, rp.char_offset,
                     rp.updated_at
              FROM reader_positions rp''');
              await customStatement('DROP TABLE reader_positions');
              await customStatement(
                  'ALTER TABLE reader_positions_v82 RENAME TO reader_positions');
            }
            if (hasEpubBooks &&
                await _tableExists('bookmarks') &&
                await _columnExists('bookmarks', 'book_key')) {
              await customStatement('''
              CREATE TABLE bookmarks_v82 (
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                book_uid TEXT NOT NULL,
                section_index INTEGER NOT NULL,
                norm_char_offset INTEGER NOT NULL,
                label TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                book_title TEXT,
                page_in_chapter INTEGER,
                total_pages_in_chapter INTEGER)''');
              await customStatement('''
              INSERT INTO bookmarks_v82
                (id, book_uid, section_index, norm_char_offset, label,
                 created_at, book_title, page_in_chapter,
                 total_pages_in_chapter)
              SELECT bm.id, eb.uid, bm.section_index, bm.norm_char_offset,
                     bm.label, bm.created_at, bm.book_title,
                     bm.page_in_chapter, bm.total_pages_in_chapter
              FROM bookmarks bm
              JOIN epub_books eb
                ON eb.book_key = bm.book_key AND eb.uid != ''
              ''');
              await customStatement('DROP TABLE bookmarks');
              await customStatement(
                  'ALTER TABLE bookmarks_v82 RENAME TO bookmarks');
            }
            if (hasEpubBooks &&
                await _tableExists('book_custom_css') &&
                await _columnExists('book_custom_css', 'book_key')) {
              await customStatement('''
              CREATE TABLE book_custom_css_v82 (
                book_uid TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                content TEXT NOT NULL DEFAULT '',
                deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (book_uid, relative_path))''');
              await customStatement('''
              INSERT INTO book_custom_css_v82
                (book_uid, relative_path, content, deleted, updated_at)
              SELECT eb.uid, c.relative_path, c.content, c.deleted,
                     c.updated_at
              FROM book_custom_css c
              JOIN epub_books eb
                ON eb.book_key = c.book_key AND eb.uid != ''
              ''');
              await customStatement('DROP TABLE book_custom_css');
              await customStatement(
                  'ALTER TABLE book_custom_css_v82 RENAME TO book_custom_css');
            }
            if (hasEpubBooks &&
                await _tableExists('revealed_images') &&
                await _columnExists('revealed_images', 'book_key')) {
              await customStatement('''
              CREATE TABLE revealed_images_v82 (
                book_uid TEXT NOT NULL,
                image_key TEXT NOT NULL,
                revealed_at INTEGER NOT NULL,
                PRIMARY KEY (book_uid, image_key))''');
              await customStatement('''
              INSERT INTO revealed_images_v82
                (book_uid, image_key, revealed_at)
              SELECT eb.uid, r.image_key, r.revealed_at
              FROM revealed_images r
              JOIN epub_books eb
                ON eb.book_key = r.book_key AND eb.uid != ''
              ''');
              await customStatement('DROP TABLE revealed_images');
              await customStatement(
                  'ALTER TABLE revealed_images_v82 RENAME TO revealed_images');
            }
            // 书签索引换列成对重建（旧 idx 已随 DROP TABLE 消亡；本索引与
            // idx_epub_books_uid 同理不进 _ensureIndexes——那个清单会被更早
            // 的迁移步调用，彼时新列还不存在）。
            if (await _tableExists('bookmarks') &&
                await _columnExists('bookmarks', 'book_uid')) {
              await customStatement(
                  'CREATE INDEX IF NOT EXISTS idx_bookmarks_book_uid_created '
                  'ON bookmarks (book_uid, created_at DESC)');
            }
          }
          if (from < 83 && await _tableExists('epub_books')) {
            // v83（P3 Stage 2）：shelf_entries / media_collection_items 的
            // epub 域 entryKey 从 bookKey 换稳定 uid；media_collections 的
            // cover_source 'epub|<key>' 同步换键。
            // - 远端透传行（epub 无本地行）**照抄保留**——与 v82 清孤儿刻意
            //   不同：合集清单是跨端 union，epub 无主行可能是「替对端转发」
            //   的远端归属，清了丢数据。
            // - 两表 PK 含 entry_key，直 UPDATE 可能撞 PK（脏数据 bookKey 行
            //   与 uid 行并存）→ create-copy-drop-rename + INSERT OR IGNORE
            //   顺带去重（v82 同形）。
            // - 重入/幂等：uid 值（book_<..>形）不落 sanitize(title) 值域，
            //   重跑 COALESCE 不再命中（病态标题恰为 book_<n>_<n> 形的碰撞
            //   概率忽略，记档于此）。
            if (await _tableExists('shelf_entries')) {
              await customStatement('''
              CREATE TABLE shelf_entries_v83 (
                media_type TEXT NOT NULL,
                entry_key TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                series_id INTEGER REFERENCES series (id) ON DELETE SET NULL,
                PRIMARY KEY (media_type, entry_key))''');
              await customStatement('''
              INSERT OR IGNORE INTO shelf_entries_v83
                (media_type, entry_key, sort_order, series_id)
              SELECT s.media_type,
                     CASE WHEN s.media_type = 'epub' THEN
                       COALESCE((SELECT eb.uid FROM epub_books eb
                                 WHERE eb.book_key = s.entry_key
                                   AND eb.uid != ''),
                                s.entry_key)
                     ELSE s.entry_key END,
                     s.sort_order, s.series_id
              FROM shelf_entries s''');
              await customStatement('DROP TABLE shelf_entries');
              await customStatement(
                  'ALTER TABLE shelf_entries_v83 RENAME TO shelf_entries');
            }
            if (await _tableExists('media_collection_items')) {
              await customStatement('''
              CREATE TABLE media_collection_items_v83 (
                collection_id INTEGER NOT NULL
                  REFERENCES media_collections (id) ON DELETE CASCADE,
                media_type TEXT NOT NULL,
                entry_key TEXT NOT NULL,
                sort_index INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (collection_id, media_type, entry_key))''');
              await customStatement('''
              INSERT OR IGNORE INTO media_collection_items_v83
                (collection_id, media_type, entry_key, sort_index)
              SELECT i.collection_id, i.media_type,
                     CASE WHEN i.media_type = 'epub' THEN
                       COALESCE((SELECT eb.uid FROM epub_books eb
                                 WHERE eb.book_key = i.entry_key
                                   AND eb.uid != ''),
                                i.entry_key)
                     ELSE i.entry_key END,
                     i.sort_index
              FROM media_collection_items i''');
              await customStatement('DROP TABLE media_collection_items');
              await customStatement('ALTER TABLE media_collection_items_v83 '
                  'RENAME TO media_collection_items');
            }
            if (await _tableExists('media_collections')) {
              // frozen-migration-literal（BUG-1489）：下面这两处 `'epub|'` 是
              // **冻结历史串**，绝不能换成 `MediaKind.epub.dbValue`。迁移步读写的
              // 是「升到 v83 那一刻磁盘上真实存在」的形态：`LIKE 'epub|%'` 认老行、
              // `substr(cover_source, 6)`（6 = len('epub|') + 1）切 bookKey。引用
              // 运行时枚举串后，谁改了 dbValue 这段历史迁移就跟着漂——老库匹配不上、
              // 换键静默不做，而同一步里不带前缀的 shelf_entries /
              // media_collection_items 照常换成了 uid，cover_source 从此永久悬空。
              await customStatement('''
              UPDATE media_collections SET cover_source = 'epub|' ||
                (SELECT eb.uid FROM epub_books eb
                 WHERE eb.book_key = substr(cover_source, 6)
                   AND eb.uid != '')
              WHERE cover_source LIKE 'epub|%'
                AND EXISTS (SELECT 1 FROM epub_books eb
                            WHERE eb.book_key = substr(cover_source, 6)
                              AND eb.uid != '')''');
            }
          }
        },
        onCreate: (m) async {
          await m.createAll();
          // 与 v81 步成对：uid 唯一索引不进 _ensureIndexes（会被早期迁移步在
          // 列不存在时调用），fresh 库在此内联补上。
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS idx_epub_books_uid '
              "ON epub_books (uid) WHERE uid != ''");
          // 与 v82 步成对：书签索引换 book_uid 列，同理不进 _ensureIndexes。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_bookmarks_book_uid_created '
              'ON bookmarks (book_uid, created_at DESC)');
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

          // A hard process exit cannot run HomePage.dispose, so a scrape run
          // left in `running` would otherwise remain active forever. Reconcile
          // it before any app query can observe the database or start a new
          // batch. An actually running task cannot survive the process boundary
          // that opened this handle, while terminal rows remain untouched.
          if (_isMainProcess &&
              await _tableExists('video_source_scrape_runs')) {
            final int interruptedAt = DateTime.now().millisecondsSinceEpoch;
            await (update(videoSourceScrapeRuns)
                  ..where(($VideoSourceScrapeRunsTable t) =>
                      t.status.equals('running')))
                .write(VideoSourceScrapeRunsCompanion(
              status: const Value<String>('interrupted'),
              phase: const Value<String?>('interrupted'),
              lastError: const Value<String?>(
                'Application ended before the scrape completed',
              ),
              updatedAt: Value<int>(interruptedAt),
              finishedAt: Value<int?>(interruptedAt),
            ));
          }
        },
      );

  /// 迁移用批量文本前缀改写：把 [table].[column] 里以 [from] 开头的值改写成
  /// [to] + 余下部分（`to` 可为空串 = 剥前缀）。`LIKE` 的 `_`/`%` 通配符已按
  /// ESCAPE 规则转义，前缀是逐字面匹配。`UPDATE OR REPLACE`：目标列可能是主键
  /// （preferences.key）或 UNIQUE（media_items.unique_key），改写撞上已有行时
  /// 保留改写结果而不是让整条 onUpgrade 中断。调用方负责 `_tableExists` 守卫。
  Future<void> _rewriteTextPrefix({
    required String table,
    required String column,
    required String from,
    required String to,
    String? extraWhere,
  }) async {
    if (!_FushiDbInfra._identifierRe.hasMatch(table) ||
        !_FushiDbInfra._identifierRe.hasMatch(column)) {
      throw ArgumentError('not a valid identifier: $table.$column');
    }
    String sqlQuote(String s) => s.replaceAll("'", "''");
    final String likePrefix =
        sqlQuote(from).replaceAllMapped(RegExp(r'[_%\\]'), (m) => '\\${m[0]}');
    await customStatement(
      'UPDATE OR REPLACE $table '
      "SET $column = '${sqlQuote(to)}' || substr($column, ${from.length + 1}) "
      "WHERE $column LIKE '$likePrefix%' ESCAPE '\\'"
      '${extraWhere == null ? '' : ' AND ($extraWhere)'}',
    );
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
  /// 但这里是独立实现：fushi_core 是 app 的依赖，不能反向 import app 代码。
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

  // ── 类级常量/静态键（被 `FushiDatabase.x` 形式跨库引用，extension 的
  // static 需 extension 名限定，故集中留在类体；方法本体在各 part）──

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

  /// 合集级删除墓碑的哨兵值：mediaType 与 entryKey 皆为 ''（真实成员键恒非空，
  /// 无歧义）。
  static const String collectionTombstoneSentinel = '';

  /// 收藏词跨设备稳定身份键（= uniqueKey {expression, reading, sourceType} 的 NUL 连接串），
  /// 用作 `favoriteword` sync 删除墓碑的 itemKey。NUL 分隔符文本几乎不可能出现（同项目
  /// NUL 分组键约定），可逆解析见 app 层 `parseFavoriteWordItemKey`。
  static String favoriteWordItemKey(
          String expression, String reading, String sourceType) =>
      '$expression\u0000$reading\u0000$sourceType';

  /// 上限：保留最近 [kMinedSentenceHistoryLimit] 条制卡历史，避免无限增长。
  static const int kMinedSentenceHistoryLimit = 1000;

  /// sourceType 常量：与统计聚合 / lookup_mining_counters 的 source_type 同值。
  static const String statSourceBook = 'book';
  static const String statSourceVideo = 'video';

  /// 统计日分组键（本地时区 `yyyy-MM-dd`）的**唯一权威派生**（P4 写侧收敛 A 组）。
  /// app 层 `statDateKey` / 视频桶拆分等统计写入面的 dateKey 一律直接或间接走
  /// 这里，别再各自格式化一份。委托 [_FushiDbStatistics.statDateKeyOf]（复合
  /// 入口 recordReadingSession / recordMiningEvent 在 DB 层派生 dateKey 用的
  /// 同一实现）。
  static String statDateKeyOf(DateTime d) =>
      _FushiDbStatistics.statDateKeyOf(d);
}

int _epubBookUidCounter = 0;

/// 书的本机稳定 uid 生成（v81 / P3 Stage 1）：`book_<微秒时刻>_<进程内计数>`。
/// 与迁移回填的 `book_<rowid>_<秒时刻>` 同命名空间不同后缀形，互不相撞；
/// 进程内计数器兜同微秒批量导入。**机器局域**身份，不进 wire（那边仍是
/// bookKey）；跨设备无需一致。
String generateEpubBookUid() => 'book_${DateTime.now().microsecondsSinceEpoch}_'
    '${_epubBookUidCounter++}';

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
