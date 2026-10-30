import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
// drift/remote.dart 标了 experimental，但 DriftRemoteException 是后台 isolate 连接
// 抛错的唯一载体，开库时要靠它还原类型化异常（见 _TypedOpenErrorInterceptor）。
// ignore: experimental_member_use
import 'package:drift/remote.dart' show DriftRemoteException;
import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../utils/fushi_debug_print.dart';
import 'activity_event_types.dart';
import 'book_format.dart';
import 'collection_order.dart';
import 'collection_organize.dart';
import 'collection_book_identity.dart';
import 'epub_book_meta.dart';
import 'galgame_text_line_tables.dart';
import 'media_kind.dart';
import 'media_kind_mappings.dart';
import 'media_image_kind.dart';
import 'media_link_kind.dart';
import 'music_scrape_tables.dart';
import 'music_tables.dart';
import 'pref_codec.dart';
import 'sync_tombstone_kind.dart';
import 'tables.dart';
import 'tag_host_kind.dart';
import 'people_tables.dart';
import 'theme_song_span_tables.dart';

part 'database.g.dart';
part 'database_infra.part.dart';
part 'database_prefs_media.part.dart';
part 'database_video_domain.part.dart';
part 'database_library.part.dart';
part 'database_statistics.part.dart';
part 'database_content_misc.part.dart';
part 'database_tags_sync.part.dart';
part 'database_update_feed.part.dart';
part 'database_manga_download.part.dart';
part 'database_srs.part.dart';
part 'database_web_browser.part.dart';
part 'database_media_links.part.dart';
part 'database_galgame_text_lines.part.dart';
part 'database_music.part.dart';
part 'database_music_scrape.part.dart';
part 'database_theme_song_spans.part.dart';
part 'database_people.part.dart';
part 'database_ai_agent.part.dart';

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

/// 本版本仍能原地升级的最低库 schema（含）。低于它的迁移阶梯（Hibiki 时代的
/// `hibiki_paired_peers` / `reader_ttu` / `sasayaki` / `hoshi://` /
/// `s:hibikiServer` 等存量改写，最高到 v74）已从本版本删除。
///
/// 选 75 的依据：最后一条改写旧字面量的台阶是 v74；改名后首个正式版 v2.2.4
/// 出货的已是 schema v94，此后所有正式版都 ≥ 94，只有停在改名前（Hibiki v2.1.1
/// 及更早，schema ≤ 68）或从未升级过的库会落到门槛以下。这类库要先装
/// [kLegacySchemaBridgeAppVersion]（仍带完整阶梯）打开一次升级，再装本版本。
const int kMinSupportedSchemaVersion = 75;

/// 仍带完整迁移阶梯、可把门槛以下老库升上来的最新正式版（UI 提示用户先装它）。
const String kLegacySchemaBridgeAppVersion = '2.9.1';

/// [kLegacySchemaBridgeAppVersion] 的 GitHub Release 页（门槛提示里的下载链接）。
/// 2026-10-14 经 `gh release view v2.9.1` 核实：正式版、非预发布。
const String kLegacySchemaBridgeReleaseUrl =
    'https://github.com/hajisensai/fushi/releases/tag/'
    'v$kLegacySchemaBridgeAppVersion';

/// 库的 schema 低于 [kMinSupportedSchemaVersion]（或目录里只有改名前的
/// `hibiki.db`），本版本已不含能把它升上来的迁移代码。
///
/// 与 [FushiDatabaseDowngradeException] 同一套拦截方式：在 drift 最早的迁移钩子里
/// 抛出，迁移事务不提交、`user_version` 不前移、库文件原样保留；绝不建空库顶替。
/// app 层识别这个类型，提示用户先装 [kLegacySchemaBridgeAppVersion] 打开一次再更新。
/// 备份恢复 / 合并导入在覆盖或合并前用 [checkSupportedSchemaVersion] 做同样的判定。
class UnsupportedLegacySchemaException implements Exception {
  /// 库里的 schema（`PRAGMA user_version`）；只发现旧文件名 `hibiki.db` 而未读
  /// 版本时为 null。
  final int? dbVersion;

  /// 本版本支持的最低 schema（[kMinSupportedSchemaVersion]）。
  final int minSupportedVersion;

  /// 触发拒绝的文件路径（诊断用；可为 null）。
  final String? dbPath;

  const UnsupportedLegacySchemaException({
    required this.dbVersion,
    this.minSupportedVersion = kMinSupportedSchemaVersion,
    this.dbPath,
  });

  @override
  String toString() =>
      'UnsupportedLegacySchemaException: database '
      '${dbPath == null ? '' : '"$dbPath" '}'
      '(schema ${dbVersion == null ? 'pre-rename hibiki.db' : 'v$dbVersion'}) '
      'is older than the minimum this version can upgrade '
      '(schema v$minSupportedVersion). Install Fushi '
      'v$kLegacySchemaBridgeAppVersion, open it once to upgrade the data, then '
      'install this version ($kLegacySchemaBridgeReleaseUrl). The database '
      'was left untouched.';
}

/// 判定一个外来库的 schema 能否被本版本接手（备份恢复 / 合并导入 / 迁移导入在
/// 覆盖或合并之前调用）。`0`（非 drift 库 / 空文件）不归本函数管，交给原有校验。
void checkSupportedSchemaVersion(int userVersion, {String? dbPath}) {
  if (userVersion > 0 && userVersion < kMinSupportedSchemaVersion) {
    throw UnsupportedLegacySchemaException(
      dbVersion: userVersion,
      dbPath: dbPath,
    );
  }
}

/// 从 SQLite 文件头读 `user_version`（偏移 60，4 字节大端）。[header] 不足 64
/// 字节或不是 SQLite 文件头时返回 null。只读文件头，不开连接、不碰 `-wal`。
int? sqliteUserVersionFromHeader(List<int> header) {
  const List<int> magic = <int>[
    0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, //
    0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
  ];
  if (header.length < 64) return null;
  for (int i = 0; i < magic.length; i++) {
    if (header[i] != magic[i]) return null;
  }
  return (header[60] << 24) | (header[61] << 16) | (header[62] << 8) | header[63];
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
/// BUG-1899：终态失败的两种**根本不同**的成因。此前它们共用一句「likely corrupt,
/// must be restored from a backup or cleared」，把「路径压根打不开」说成了「数据坏了」，
/// 并把用户引向清空数据——而那种情况下磁盘上一个字节都没损坏。
enum FushiDatabaseFailureKind {
  /// 文件在，但内容不是合法的 SQLite（或恢复阶梯已穷尽）。真的坏了：只能恢复备份或清空。
  corrupt,

  /// 根本打不开：父目录不存在、无权限、只读介质、盘断链。
  /// **磁盘上什么都没坏**，让用户去清空数据是有害的误导。
  cannotOpen,
}

class FushiDatabaseUnrecoverableException implements Exception {
  /// Absolute path of the database file that could not be recovered.
  final String dbPath;

  /// The underlying error from the final open attempt (kept for diagnostics).
  final Object cause;

  /// 区分「文件坏了」与「路径打不开」，见 [FushiDatabaseFailureKind]。
  final FushiDatabaseFailureKind kind;

  const FushiDatabaseUnrecoverableException({
    required this.dbPath,
    required this.cause,
    this.kind = FushiDatabaseFailureKind.corrupt,
  });

  @override
  String toString() => switch (kind) {
        FushiDatabaseFailureKind.corrupt =>
          'FushiDatabaseUnrecoverableException: the database file at "$dbPath" '
              'could not be opened even after WAL/sidecar recovery. It is '
              'likely corrupt and must be restored from a backup or cleared. '
              'Cause: $cause',
        FushiDatabaseFailureKind.cannotOpen =>
          'FushiDatabaseUnrecoverableException: the database file at "$dbPath" '
              'could not be opened and does not exist on disk — the folder is '
              'missing, unwritable, or on a disconnected/read-only volume. '
              'Nothing is corrupt; check the data location. Cause: $cause',
      };
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
      // BUG-1899：这里必须分清两件事。sqlite 的 open 在父目录存在时会**自己创建**
      // 缺失的 db 文件，所以走到这一步还「文件不存在」，只可能是连创建都失败了 ——
      // 目录不存在 / 无权限 / 只读介质 / 盘断链。那不是「损坏」，把它说成损坏会把
      // 用户引去清空数据（用户报告：自定义数据安装位置后启动即「Database damaged」，
      // 实际只是 `<dataRoot>/support` 这个空目录没被创建）。
      // 文件确实在但头不是 SQLite magic → 才是真的坏了。
      throw FushiDatabaseUnrecoverableException(
        dbPath: path,
        cause: e,
        kind: File(path).existsSync()
            ? FushiDatabaseFailureKind.corrupt
            : FushiDatabaseFailureKind.cannotOpen,
      );
    }
    fushiDebugPrint('[fushi-db] sidecar open error on "$path" '
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
    fushiDebugPrint(
        '[fushi-db] Layer 1 recovery OK (checkpoint+DELETE) for "$path"');
    return NativeDatabase.createInBackground(dbFile, setup: applyPragmas);
  } catch (e, stack) {
    if (!_isSidecarOpenError(e)) rethrow;
    fushiDebugPrint('[fushi-db] Layer 1 still failing on "$path": $e\n$stack');
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
    fushiDebugPrint(
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
///
/// Exact names produced (the whitelist in [databaseSnapshotMainFileName] must
/// match these verbatim): `fushi.db.corrupt-bak-<stamp>.db`,
/// `fushi.db.corrupt-bak-<stamp>.db-wal`, `fushi.db.corrupt-bak-<stamp>.db-shm`
/// — the copied file's own extension is appended AFTER the stamp, so a snapshot
/// never ends in a bare `-wal` / `-shm`.
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
        fushiDebugPrint(
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
  fushiDebugPrint('[fushi-db] Layer 2: deleted stale -wal/-shm for "$path" '
      '(main .db untouched, .corrupt-bak-$stamp snapshot kept)');
}

/// 主库在 support 根下的文件名。唯一真相源：除了 [_openDb] 自身，app 层判定「这台机器
/// 上是否已经有一个跑过的安装」时也要认这个文件（见 `AppPaths` 的默认 documents
/// 布局判据），故抽成导出常量而不是各处重复字面量。
const String fushiDatabaseFileName = 'fushi.db';

/// 旧主库文件名（Fushi 改名前的 Hibiki 时代）。本版本不再改名迁移它：[_openDb] 发现
/// 目录里只有它时抛 [UnsupportedLegacySchemaException]（见
/// [_rejectPreRenameDatabase]）。app 层「本机是否已有安装」的判据也要兼看它，
/// 否则老安装会被当成全新安装、换到别的数据根上建空库；存储页仍按它识别改名前
/// 留下的快照残留（`hibiki.db.bak.v*` 等）供用户清理。
const String legacyHibikiDatabaseFileName = 'hibiki.db';

/// 主库**快照残留**的识别口径（BUG-1870；存储页「数据库备份快照」条目与
/// [deleteDatabaseSnapshotFiles] 共用，展示什么就删什么）。
///
/// 判据是**两层**，缺一层就会误删活数据：
///
/// **层 (a) 形态白名单（本函数）** —— 只认代码**真的产过**的「整文件副本」命名，
/// 逐条列举，不做「不在排除表里就算残留」的黑名单推断：
///
/// - [_rebuildSidecar] 的崩溃恢复快照：`<主库名>.corrupt-bak-<毫秒戳>.db`
///   / `.db-wal` / `.db-shm`（副本名以 `.db*` 结尾，不是 `-wal`/`-shm`）；
/// - 旧版降级救援副本（`from > to` 的销毁式分支早已删除，只在老用户盘上留着）：
///   `<主库名>[-wal|-shm].bak.v<旧schema>.<毫秒戳>`；
/// - `backup_service` 的导入前快照：`<主库名>.pre-restore.bak`
///   / `<主库名>.pre-merge.bak`。
///
/// 黑名单在这里是**危险**的：`backup_service` 把一整族**活控制文件**放在同一个
/// support 根、且同样以主库名开头 —— `fushi.db.sync-preserve.json`（待恢复标记）、
/// `fushi.db.merge-preserve.json`、`fushi.db.merge-src[-wal|-shm]`、
/// `fushi.db.merge-preview-src`。它们不是副本，删掉会让 `recoverPendingRestore`
/// 在下次启动时静默 `return`，用户的 LAN 配对 / 同步基线 / 被排除的 settings、
/// profiles 层永久丢失。白名单让「新加一个控制文件」默认安全（不认识 ⇒ 不碰），
/// 黑名单则默认危险（忘了补一行 ⇒ 可删）。
///
/// **层 (b) 所有权门控（[isDeletableDatabaseSnapshot]）** —— 形态命中也未必是
/// 残留：`pre-restore.bak` 由 `sync-preserve.json` 持有、`pre-merge.bak` 由
/// `merge-preserve.json` 持有。恢复流程半途失败时**两个文件都会被刻意保留**，
/// 下次启动靠它们补完（见 `backup_service.recoverPendingRestore`）。只要 sidecar
/// 还在，被它拥有的副本就是活的恢复输入，不得列出、不得删除；sidecar 不在时它
/// 才是孤儿。「能不能删」因此由「有没有活的恢复流程指向它」这个真实关系决定，
/// 而不是由文件名碰巧不在某个排除表里决定。
///
/// 活库本体与 `-wal` / `-shm` / `-journal` 侧车形态上就不在白名单里，结构上永远
/// 不可能命中（改名前的活库 `hibiki.db` 同样不命中——它会被 [_openDb] 拒绝打开，
/// 绝不能被当成残留删掉）。
bool isDatabaseSnapshotFileName(final String name) =>
    databaseSnapshotMainFileName(name) != null;

/// 崩溃恢复快照后缀（[_rebuildSidecar]：`.corrupt-bak-<stamp>` + 被复制文件的
/// `.db` / `.db-wal` / `.db-shm`）。
final RegExp _kCorruptBakSuffix =
    RegExp(r'^\.corrupt-bak-\d+\.db(-wal|-shm)?$');

/// 旧降级救援副本后缀（`.bak.v<旧schema>.<毫秒戳>`）。
final RegExp _kLegacyDowngradeBakSuffix = RegExp(r'^\.bak\.v\d+\.\d+$');

/// `backup_service` 导入前快照的后缀（只挂主库名，不挂侧车名）。
const List<String> _kImportBakSuffixes = <String>[
  '.pre-restore.bak',
  '.pre-merge.bak',
];

/// 层 (b) 的所有权表：**快照文件名 → 持有它的恢复流程标记文件名**。真相源是
/// `backup_service`（`_preserveSidecar` / `_mergeSidecar` 与 `recoverPendingRestore`
/// / `recoverMergeRestore` 的成对删除）。
const Map<String, String> _kSnapshotOwnerSidecar = <String, String>{
  '$fushiDatabaseFileName.pre-restore.bak':
      '$fushiDatabaseFileName.sync-preserve.json',
  '$fushiDatabaseFileName.pre-merge.bak':
      '$fushiDatabaseFileName.merge-preserve.json',
};

/// 层 (a)：[name] 命中快照白名单时返回它所属的主库名（[fushiDatabaseFileName] 或
/// [legacyHibikiDatabaseFileName]），否则返回 null。存储页用它给聚合条目起
/// 「实际命中的是哪个库名」的标题，形态判定因此只有这一份实现。
String? databaseSnapshotMainFileName(final String name) {
  for (final String db in const <String>[
    fushiDatabaseFileName,
    legacyHibikiDatabaseFileName,
  ]) {
    if (!name.startsWith(db)) continue;
    // 旧降级救援把活库的 `-wal` / `-shm` 也整份复制过，所以词干允许带侧车后缀；
    // 长的先试，否则 `hibiki.db-wal.bak.v20.1` 会先被裸库名截走。
    for (final String stem in <String>['$db-wal', '$db-shm', db]) {
      if (!name.startsWith(stem)) continue;
      final String rest = name.substring(stem.length);
      if (_kLegacyDowngradeBakSuffix.hasMatch(rest)) return db;
      if (stem == db &&
          (_kCorruptBakSuffix.hasMatch(rest) ||
              _kImportBakSuffixes.contains(rest))) {
        return db;
      }
      break;
    }
    return null;
  }
  return null;
}

/// 层 (b)：返回**可能**持有 [name] 的恢复流程标记文件名；null = 没有任何流程会
/// 持有它（形态上就是纯残留副本）。
String? databaseSnapshotOwnerFileName(final String name) =>
    _kSnapshotOwnerSidecar[name];

/// 「这个文件现在可以列出/删除吗」的**唯一**对外判据：形态命中白名单，且没有活
/// 的恢复流程持有它。[siblingFileNames] 是该文件所在目录的直接子项名集合
/// （存储页在扫描 isolate 里已经有这份清单，无需二次 IO）。
bool isDeletableDatabaseSnapshot(
  final String name,
  final Set<String> siblingFileNames,
) {
  if (!isDatabaseSnapshotFileName(name)) return false;
  final String? owner = databaseSnapshotOwnerFileName(name);
  return owner == null || !siblingFileNames.contains(owner);
}

/// [supportRoot] **直接**子层里可删的主库快照残留（同步、不递归、不追 symlink；
/// 存储页在扫描 isolate 里调用）。所有权门控的兄弟名集合取自同一次 listSync，
/// 所以「列出」与「删除」看到的是同一个目录快照。
List<File> listDatabaseSnapshotFiles(final Directory supportRoot) {
  if (!supportRoot.existsSync()) return const <File>[];
  final List<FileSystemEntity> children =
      supportRoot.listSync(followLinks: false);
  final Set<String> names = <String>{
    for (final FileSystemEntity e in children) p.basename(e.path),
  };
  return <File>[
    for (final FileSystemEntity e in children)
      if (e is File && isDeletableDatabaseSnapshot(p.basename(e.path), names))
        e,
  ];
}

/// [deleteDatabaseSnapshotFiles] 的结果。删除是**逐文件容错**的：Windows 上
/// Defender / 索引器临时占住某个副本是常态，一个失败就整批中止会让用户点了删除
/// 却几十个文件一个没少。
class DatabaseSnapshotDeletionResult {
  const DatabaseSnapshotDeletionResult({
    required this.deleted,
    required this.failures,
  });

  /// 已删除的绝对路径。
  final List<String> deleted;

  /// 删不掉的：路径 → 失败原因（原样带给 UI 提示，不吞）。
  final Map<String, String> failures;

  bool get hasFailures => failures.isNotEmpty;
}

/// 删除 [supportRoot] 下全部可删的主库快照残留。识别口径与
/// [listDatabaseSnapshotFiles] 同源（含所有权门控），故活库/侧车/待恢复副本结构
/// 上不可能被删到。单个文件删不掉不中止整批：收集失败原因后继续删剩下的。
Future<DatabaseSnapshotDeletionResult> deleteDatabaseSnapshotFiles(
    final Directory supportRoot) async {
  final List<String> deleted = <String>[];
  final Map<String, String> failures = <String, String>{};
  for (final File f in listDatabaseSnapshotFiles(supportRoot)) {
    try {
      await f.delete();
      deleted.add(f.path);
    } on FileSystemException catch (e) {
      failures[f.path] = e.osError?.message ?? e.message;
    }
  }
  return DatabaseSnapshotDeletionResult(deleted: deleted, failures: failures);
}

/// 改名前的 Hibiki 安装只有 `hibiki.db`：它的 schema 必然低于
/// [kMinSupportedSchemaVersion]（改名迁移与库内改写阶梯都已从本版本删除），所以
/// 不再改名，而是在**打开任何连接之前**拒绝：`fushi.db` 不存在且 `hibiki.db`
/// 存在时抛 [UnsupportedLegacySchemaException]。绝不能放行到 [_openWithRecovery]——
/// 那会在旁边建一个空 `fushi.db`，用户看到的是「数据全没了」，下一次启动连这条
/// 判据都不再命中（`fushi.db` 已存在）。
Future<void> _rejectPreRenameDatabase(String dbDirectory) async {
  final File newDb = File(p.join(dbDirectory, fushiDatabaseFileName));
  final File oldDb = File(p.join(dbDirectory, legacyHibikiDatabaseFileName));
  if (await newDb.exists() || !await oldDb.exists()) return;
  throw UnsupportedLegacySchemaException(dbVersion: null, dbPath: oldDb.path);
}

/// 开库拒绝类异常（[FushiDatabaseDowngradeException] /
/// [UnsupportedLegacySchemaException]）是 app 层**按类型分派**的契约：各自对应一块
/// 专屏 / 一句提示。但生产开库走后台 isolate 的 drift 连接，迁移钩子在调用方 isolate
/// 里抛出的异常要经 drift 的请求通道绕一圈回来，到调用方手里已被包成（可能多层）
/// [DriftRemoteException]——`on FushiDatabaseDowngradeException` 永远接不住，用户
/// 只看到通用错误屏和一个无效的「重试」。这里在开库这一步把它们原样还原。
class _TypedOpenErrorInterceptor extends QueryInterceptor {
  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) async {
    try {
      return await executor.ensureOpen(user);
    } on DriftRemoteException catch (e, stack) {
      Object cause = e;
      StackTrace? causeStack = stack;
      while (cause is DriftRemoteException) {
        causeStack = cause.remoteStackTrace ?? causeStack;
        cause = cause.remoteCause;
      }
      if (cause is FushiDatabaseDowngradeException ||
          cause is UnsupportedLegacySchemaException) {
        Error.throwWithStackTrace(cause, causeStack ?? stack);
      }
      rethrow;
    }
  }
}

LazyDatabase _openDb(String dbDirectory, {bool isMainProcess = true}) {
  return LazyDatabase(() async {
    await _rejectPreRenameDatabase(dbDirectory);
    final file = File(p.join(dbDirectory, fushiDatabaseFileName));
    final QueryExecutor executor =
        await _openWithRecovery(file, allowSidecarDelete: isMainProcess);
    return executor.interceptWith(_TypedOpenErrorInterceptor());
  });
}

/// Opens an arbitrary `.db` FILE (not a directory). Used by the backup MERGE
/// import (TODO-888) to migrate an extracted backup DB up to the current schema
/// before ATTACHing it to the live DB. Same robust open as [_openDb].
LazyDatabase _openDbFile(String dbFilePath, {bool isMainProcess = true}) {
  return LazyDatabase(() async {
    final file = File(dbFilePath);
    final QueryExecutor executor =
        await _openWithRecovery(file, allowSidecarDelete: isMainProcess);
    return executor.interceptWith(_TypedOpenErrorInterceptor());
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
  LanguageProfiles,
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
  CollectionBookAliases,
  FushiPairedPeers,
  BookTombstones,
  LookupMiningCounters,
  StatisticsTombstones,
  BookTagMembershipTombstones,
  BookCustomCss,
  MangaReaderOverrides,
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
  MangaChapterStates,
  StudySegmentTombstones,
  StudySegments,
  WebMineQueue,
  VideoFileSpecs,
  UpdateFeedEntries,
  MangaDownloadJobs,
  AnidbFileIdentities,
  VideoEpisodeBindingOverrides,
  PendingMineQueue,
  VideoSubtitleGlossaries,
  MediaPrivacyFlags,
  LibraryOrganizeRuns,
  LibraryOrganizeChanges,
  WebBrowserHistory,
  WebBrowserBookmarks,
  WebBrowserSessionTabs,
  WebBrowserClosedTabs,
  WebBrowserDownloads,
  MediaLinks,
  MusicTracks,
  MusicAlbums,
  MusicArtists,
  MusicTrackCredits,
  MusicLyrics,
  MusicVideos,
  MusicDiscSources,
  MusicPlaylists,
  MusicPlaylistEntries,
  MusicPlayEvents,
  VideoThemeSongSpans,
  MusicScrapeMeta,
  MusicMetadataRawSnapshots,
  MusicLockedFields,
  GameVoiceCasts,
  PersonIdentityBridges,
  AdaptationProgressAnchors,
  GalgameTextLines,
  AiAgentSessions,
  AiAgentActions,
  RemoteAudioBindings,
])
class FushiDatabase extends _$FushiDatabase
    with
        _FushiDbInfra,
        _FushiDbSrs,
        _FushiDbTagsSync,
        _FushiDbLibrary,
        _FushiDbPrefsMedia,
        _FushiDbContentMisc,
        _FushiDbStatistics,
        _FushiDbVideoDomain,
        _FushiDbUpdateFeed,
        _FushiDbMangaDownload,
        _FushiDbWebBrowser,
        _FushiDbMediaLinks,
        _FushiDbMusic,
        _FushiDbMusicScrape,
        _FushiDbThemeSongSpans,
        _FushiDbPeople,
        _FushiDbGalgameTextLines,
        _FushiDbAiAgent {
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
  int get schemaVersion => 139;

  /// v125–v128 四步的产物（全部幂等）：SRS 写路径索引、
  /// `collection_member_tombstones.published_at`、`bookmarks.char_offset` /
  /// `chapter_key`、内置浏览器五张表。两条并行迁移史争用 v125–v131，onUpgrade
  /// 对 `from < 132` 的库一律调它（见 onUpgrade 里该段的说明）。
  Future<void> _ensureV125ToV128Artifacts(Migrator m) async {
    {
      // v125（SRS 写入路径读放大）：idx_srs_field_edits_profile_register（同步冲突角标的
      // 分组只扫索引）、idx_srs_notes_cache_type（笔记类型成员查找）、
      // idx_srs_notes_cache_pending（待裁决笔记的部分索引），见 _ensureSrsIndexes。只加
      // 索引、不动数据；全部 IF NOT EXISTS，幂等。表在阶梯上不存在（合成库）则跳过。
      if (await _tableExists('srs_field_edits') &&
          await _tableExists('srs_notes_cache')) {
        await _ensureSrsIndexes();
      }
    }
    {
      // v126：collection_member_tombstones.published_at——墓碑知识进入本库的时刻，
      // 本机作互联 host 时作清单 publishedAt / deletedPublishedAt 输出（BUG-3743
      // 后续：host 不存它时 GET 永远回 null，对端只能回退移出时刻判新旧，离线早移出、
      // 晚同步的墓碑会被基线更新的对端判成旧闻、成员复活）。存量行留 NULL（回退
      // deleted_at，与升级前行为一致）。幂等守卫同 v119。
      if (await _tableExists('collection_member_tombstones') &&
          !await _columnExists(
              'collection_member_tombstones', 'published_at')) {
        await m.addColumn(collectionMemberTombstones,
            collectionMemberTombstones.publishedAt);
      }
    }
    {
      // v127（阅读器书签回归）：bookmarks.char_offset——书签页首字符的章内精确
      // 偏移（改字号后页码会变、字符不变，存量 -1 = 回退 norm_char_offset 分数）；
      // bookmarks.chapter_key——在线漫画书签所在章的稳定键（存量 NULL）。
      // 幂等守卫同 v119。
      if (await _tableExists('bookmarks') &&
          !await _columnExists('bookmarks', 'char_offset')) {
        await m.addColumn(bookmarks, bookmarks.charOffset);
      }
      if (await _tableExists('bookmarks') &&
          !await _columnExists('bookmarks', 'chapter_key')) {
        await m.addColumn(bookmarks, bookmarks.chapterKey);
      }
    }
    {
      // v128（内置浏览器完整化）：历史 / 书签（含文件夹）/ 标签页会话 / 最近关闭 /
      // 下载记录五张新表。纯新表、不动存量数据；幂等守卫同 v119。历史与书签随备份
      // 走、经聚合快照跨端同步，其余三张设备本地。
      if (!await _tableExists('web_browser_history')) {
        await m.createTable(webBrowserHistory);
      }
      if (!await _tableExists('web_browser_bookmarks')) {
        await m.createTable(webBrowserBookmarks);
      }
      if (!await _tableExists('web_browser_session_tabs')) {
        await m.createTable(webBrowserSessionTabs);
      }
      if (!await _tableExists('web_browser_closed_tabs')) {
        await m.createTable(webBrowserClosedTabs);
      }
      if (!await _tableExists('web_browser_downloads')) {
        await m.createTable(webBrowserDownloads);
      }
    }
  }

  /// BUG-2335: version 97 also exists in a parallel migration history without
  /// the v96 expansion column. Reuse the additive migration on open so a
  /// matching user_version cannot skip the column required by the mapper.
  Future<void> _ensureDictionaryExpandedLanguagesColumn(Migrator m) async {
    if (await _tableExists('dictionary_metadata') &&
        !await _columnExists('dictionary_metadata', 'expanded_languages_json')) {
      await m.addColumn(
          dictionaryMetadata, dictionaryMetadata.expandedLanguagesJson);
    }
  }

  /// v97：把 v52 / v57 / v87 / v88 四级台阶里「加列 / 改列名」的幂等语句重放一次，
  /// 补齐漂移库（版本号先于这些台阶被写高的库）。每条都先查 `_columnExists`，
  /// 正常库全部 no-op。语句与原台阶逐字相同，避免两处定义出现分叉。
  Future<void> _replayColumnStepsForDriftedSchema(Migrator m) async {
    // v52：合集级音轨 / 调轴记忆。
    if (await _tableExists('media_collections')) {
      if (!await _columnExists('media_collections', 'audio_track_id')) {
        await m.addColumn(mediaCollections, mediaCollections.audioTrackId);
      }
      if (!await _columnExists('media_collections', 'subtitle_delay_ms')) {
        await m.addColumn(mediaCollections, mediaCollections.subtitleDelayMs);
      }
    }
    // v87 / v88：内容语言字体链的五个 language 列。
    if (await _tableExists('dictionary_metadata') &&
        !await _columnExists('dictionary_metadata', 'language_override')) {
      await m.addColumn(
          dictionaryMetadata, dictionaryMetadata.languageOverride);
    }
    if (await _tableExists('epub_books') &&
        !await _columnExists('epub_books', 'language')) {
      await m.addColumn(epubBooks, epubBooks.language);
    }
    if (await _tableExists('video_books') &&
        !await _columnExists('video_books', 'language')) {
      await m.addColumn(videoBooks, videoBooks.language);
    }
    if (await _tableExists('srt_books') &&
        !await _columnExists('srt_books', 'language')) {
      await m.addColumn(srtBooks, srtBooks.language);
    }
    if (await _tableExists('galgames') &&
        !await _columnExists('galgames', 'language')) {
      await m.addColumn(galgames, galgames.language);
    }
    // v57：墓碑表 removed_at → deleted_at（表重建，FK OFF/ON 夹住，与 v57 同款）。
    final bool renameCollection =
        await _tableExists('collection_member_tombstones') &&
            await _columnExists('collection_member_tombstones', 'removed_at') &&
            !await _columnExists('collection_member_tombstones', 'deleted_at');
    final bool renameTag = await _tableExists(
            'book_tag_membership_tombstones') &&
        await _columnExists('book_tag_membership_tombstones', 'removed_at') &&
        !await _columnExists('book_tag_membership_tombstones', 'deleted_at');
    if (renameCollection || renameTag) {
      await customStatement('PRAGMA foreign_keys = OFF');
      try {
        if (renameCollection) {
          await m.alterTable(TableMigration(
            collectionMemberTombstones,
            columnTransformer: {
              collectionMemberTombstones.deletedAt:
                  const CustomExpression<int>('removed_at'),
            },
          ));
        }
        if (renameTag) {
          await m.alterTable(TableMigration(
            bookTagMembershipTombstones,
            columnTransformer: {
              bookTagMembershipTombstones.deletedAt:
                  const CustomExpression<int>('removed_at'),
            },
          ));
        }
      } finally {
        await customStatement('PRAGMA foreign_keys = ON');
      }
    }
  }

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
          // 最低版本门槛：低于 [kMinSupportedSchemaVersion] 的阶梯（Hibiki 时代的
          // 改名 / 存量改写，v2–v75）已删除。与降级保护同理，在任何迁移语句之前
          // 抛出，迁移事务不提交、user_version 不前移、库文件原样保留；app 层识别
          // 类型后提示先装 [kLegacySchemaBridgeAppVersion] 升级一次。
          if (from < kMinSupportedSchemaVersion) {
            throw UnsupportedLegacySchemaException(dbVersion: from);
          }
          // v84（BUG-1502）：给 preferences 一列 updated_at，让「是内容的偏好行」
          // （书改名的 `override_title://` 覆盖行）能跨端 last-write-wins。
          //
          // ⚠️ **这一步必须排在整条阶梯最前**，而不是按版本号排在末尾：迁移步一旦
          // 用 drift 的**类型化** API 读写 preferences（`getAllPrefs()` 等），类型化行
          // 映射按代码里的列集取值——列还没加时它对缺失列做 null 断言，直接把整条
          // onUpgrade 炸掉。加列是纯 additive 且带 `_columnExists` 幂等守卫，提前
          // 执行对任何版本的老库都等价。
          //
          // 存量行**刻意留 0**（=「时刻未知」），不填迁移时刻：填迁移时刻会让跨端
          // 「谁赢」由两台设备各自的升级时间决定——后升级的一侧会无条件覆盖先升级
          // 一侧的所有存量改名，而用户什么操作都没做。取 0 则存量行彼此平局，LWW
          // 平局规则「保留本机」正好等于升级前的 insert-if-absent 行为（零回归）；
          // 任一侧真正改过一次名后立刻胜出。取舍全文见 [Preferences.updatedAt]。
          if (from < 84 &&
              await _tableExists('preferences') &&
              !await _columnExists('preferences', 'updated_at')) {
            await m.addColumn(preferences, preferences.updatedAt);
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
              // 真实旧库存在 schema-version 已推进、但 v57 列改名未落地的分支血统：
              // 表仍是 video_book_uid。v79 不能假定 book_uid 必然存在，否则启动迁移
              // 直接报 no such column、整库打不开。按物理 schema 选键列；added_at
              // 同样对 v41 前形态兜底为 0，保证已知两代旧表都能无损/可解释地并表。
              final String videoEntryColumn =
                  await _columnExists('video_book_tag_mappings', 'book_uid')
                      ? 'book_uid'
                      : await _columnExists(
                              'video_book_tag_mappings', 'video_book_uid')
                          ? 'video_book_uid'
                          : throw StateError(
                              'video_book_tag_mappings has no known video key column',
                            );
              final String videoAddedAt =
                  await _columnExists('video_book_tag_mappings', 'added_at')
                      ? 'added_at'
                      : '0';
              await customStatement('INSERT OR IGNORE INTO tag_assignments '
                  '(media_kind, entry_key, tag_id, added_at) '
                  "SELECT 'video', $videoEntryColumn, tag_id, $videoAddedAt "
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
          // v85（BUG-1542）：video_books 加 last_played_at，给「有进度」这个事实
          // 补上时刻维度——合集续播锚点从此是「用户刚才在看哪一集」，不再靠「排序
          // 位置最靠后的有痕迹成员」瞎猜。
          //
          // 存量回填：从 video_watch_statistics 取每个 bookUid 的 max(last_modified)
          // （v39 起该表按 bookUid 键控）。这是磁盘上唯一可得的历史近似——不回填的话
          // 老库要等每一集都被重看一遍才恢复正确，而回填后用户现有库当场就对。回填不
          // 到的成员留 NULL，[continueMemberIndex] 对「全员无时刻」自动退回旧的位置
          // 口径（逐字节等价旧行为），对「部分有时刻」优先信有时刻的一侧。
          if (from < 85 &&
              await _tableExists('video_books') &&
              !await _columnExists('video_books', 'last_played_at')) {
            await m.addColumn(videoBooks, videoBooks.lastPlayedAt);
            if (await _tableExists('video_watch_statistics')) {
              await customStatement('''
              UPDATE video_books SET last_played_at = (
                SELECT MAX(w.last_modified) FROM video_watch_statistics w
                WHERE w.book_uid = video_books.book_uid
                  AND w.last_modified > 0)
              WHERE EXISTS (
                SELECT 1 FROM video_watch_statistics w
                WHERE w.book_uid = video_books.book_uid
                  AND w.last_modified > 0)''');
            }
          }
          if (from < 86) {
            // v86（TODO-2837 主副字幕分开调轴）：video_books 加 secondary_delay_ms、
            // media_collections 加 secondary_subtitle_delay_ms，给副字幕一套独立于
            // 主字幕的两层调轴（per-book + 系列级，镜像 v52 的 delay_ms /
            // subtitle_delay_ms 结构）。无损迁移：两列 nullable 无 default → 旧库
            // 既有行全 NULL = 副字幕继续跟随主字幕调轴（v86 前主副共用一个 offset
            // 的行为逐字节保留，Never break userspace）；用户单独调过副轨后才落
            // 非 NULL 值。守卫幂等（fresh DB 已由 onCreate 建好，重复升级
            // _columnExists 短路 no-op）。
            if (await _tableExists('video_books') &&
                !await _columnExists('video_books', 'secondary_delay_ms')) {
              await m.addColumn(videoBooks, videoBooks.secondaryDelayMs);
            }
            if (await _tableExists('media_collections') &&
                !await _columnExists(
                    'media_collections', 'secondary_subtitle_delay_ms')) {
              await m.addColumn(
                  mediaCollections, mediaCollections.secondarySubtitleDelayMs);
            }
          }
          if (from < 87) {
            // v87（内容语言字体链）：dictionary_metadata 加 language_override、
            // epub_books 加 language，给「这份内容是什么语言」一个可持久化的真值，
            // 供 content_font_chain 选字体链。
            //
            // 无损：两列 nullable 无 default → 旧库既有行全 NULL = 语言未知 =
            // 不写 font-family = 逐字节保留 v87 前的渲染（Never break userspace）。
            // 书的 language 由导入时的 dc:language 回填，存量书在下次打开时不会
            // 自动回填（不扫全库），用户可手动指定；词典的自动值走 metadataJson
            // 的 sourceLanguage，重导即有。守卫幂等（fresh DB 由 onCreate 建好，
            // 重复升级 _columnExists 短路 no-op）。
            if (await _tableExists('dictionary_metadata') &&
                !await _columnExists(
                    'dictionary_metadata', 'language_override')) {
              await m.addColumn(
                  dictionaryMetadata, dictionaryMetadata.languageOverride);
            }
            if (await _tableExists('epub_books') &&
                !await _columnExists('epub_books', 'language')) {
              await m.addColumn(epubBooks, epubBooks.language);
            }
          }
          if (from < 88) {
            // v88（内容语言字体链·其余三类资源）：视频（字幕字体链）、字幕书/
            // 有声书、galgame 各加同款 language 覆盖列。
            //
            // **必须是 v88 而不是并进上面的 v87**：v87 已经随内容语言字体链那批
            // 改动落在 develop 上跑了一整天，预发布/debug 通道与本机开发库都已经
            // 把 user_version 写成 87。塞进 `from < 87` 的列对这些库永远不会执行。
            // 实测（变异测试）下的表现是两种都很坏：读路径不抛，`language` 一律
            // 读成 NULL——功能像「设了没反应」一样静默死掉；而写路径
            // （updateVideoBookLanguage 等生成 `SET language = ?`）直接撞
            // no such column。已发布的版本号是只读的，加列只能往上开新台阶。
            //
            // 无损：三列 nullable 无 default → 旧库既有行全 NULL = 语言未知 =
            // 各消费方保持原有渲染，零破坏。守卫幂等（fresh DB 由 onCreate 建好，
            // 重复升级 _columnExists 短路 no-op）。
            if (await _tableExists('video_books') &&
                !await _columnExists('video_books', 'language')) {
              await m.addColumn(videoBooks, videoBooks.language);
            }
            if (await _tableExists('srt_books') &&
                !await _columnExists('srt_books', 'language')) {
              await m.addColumn(srtBooks, srtBooks.language);
            }
            if (await _tableExists('galgames') &&
                !await _columnExists('galgames', 'language')) {
              await m.addColumn(galgames, galgames.language);
            }
          }
          if (from < 89) {
            // v89（漫画作品页·每章状态）：新表 manga_chapter_states，把「章」从
            // `MihonLibraryEntry.currentChapterIndex` 这个单 int 升成一等实体。
            //
            // 无损：纯新增表，不动任何既有表和列。旧库升级后表为空 = 所有章都
            // 「无状态」= 作品页章节列表全显示未读、继续阅读回退到
            // `currentChapterIndex`（沿 v88 前的行为），零破坏。
            //
            // 幂等：fresh DB 由 onCreate 的 createAll 建好；重复升级被
            // `_tableExists` 短路 no-op。
            if (!await _tableExists('manga_chapter_states')) {
              await m.createTable(mangaChapterStates);
            }
          }
          if (from < 90) {
            // v90（统一代理）：下载域独立的代理三态（`download_network_proxy_mode`
            // auto/direct/custom + `download_custom_proxy`）已删除，全应用只剩系统
            // 设置里的一个代理项（`update_custom_proxy`，键名历史遗留、冻结不改），
            // 留空 = 自动（env > 系统代理 > 直连）。
            //
            // 归并规则（never break userspace）：用户在下载页显式选了 custom 且填了
            // 地址、而全局项仍为空 → 把地址搬进全局项，升级后搜番剧/字幕继续走
            // 同一个代理。全局已有值以全局为准；mode 是 auto/direct 的没有可搬的
            // 东西（direct 用户升级后跟随「自动」——这是产品决定，不是数据丢失）。
            // 搬完删两行死键及其 pref Profile 副本，迁移一次性、幂等。
            //
            // 与 v63 同范式：读 + 写 + 删同一个事务，任一步失败整体回滚、
            // user_version 停在旧版供重试。值编码沿用 PreferencesRepository 的
            // `s:` 字符串前缀。
            await transaction(() async {
              if (await _tableExists('preferences')) {
                final List<QueryRow> rows = await customSelect(
                  'SELECT key, value FROM preferences WHERE key IN '
                  "('download_network_proxy_mode', 'download_custom_proxy', "
                  "'update_custom_proxy')",
                ).get();
                final Map<String, String> legacy = <String, String>{
                  for (final QueryRow row in rows)
                    row.read<String>('key'): row.read<String>('value'),
                };
                final String downloadProxy =
                    (legacy['download_custom_proxy'] ?? 's:')
                        .substring(2)
                        .trim();
                final bool globalEmpty = (legacy['update_custom_proxy'] ?? 's:')
                    .substring(2)
                    .trim()
                    .isEmpty;
                if (legacy['download_network_proxy_mode'] == 's:custom' &&
                    downloadProxy.isNotEmpty &&
                    globalEmpty) {
                  await customStatement(
                    'INSERT OR REPLACE INTO preferences (key, value) '
                    "VALUES ('update_custom_proxy', ?)",
                    <Object?>['s:$downloadProxy'],
                  );
                }
                await customStatement(
                  'DELETE FROM preferences WHERE key IN '
                  "('download_network_proxy_mode', 'download_custom_proxy')",
                );
              }
              if (await _tableExists('profile_settings')) {
                await customStatement(
                  'DELETE FROM profile_settings '
                  "WHERE category = 'pref' AND key IN "
                  "('download_network_proxy_mode', 'download_custom_proxy')",
                );
              }
            });
          }
          if (from < 91) {
            // v91（合集级字幕偏好）：media_collections 加 subtitle_language、
            // subtitle_release_group，给「这个系列默认用哪种语言 / 哪个字幕组的
            // 字幕」一个系列级真值（镜像 v52 subtitle_delay_ms 的「系列共享、
            // nullable」结构）。无损迁移：两列 nullable 无 default → 旧库既有行
            // 全 NULL = 没人配过 = 消费方回退视频内容语言链 / 默认选轨，逐字节
            // 保留 v91 前行为（Never break userspace）；绝不回填 ja。守卫幂等
            // （fresh DB 已由 onCreate 建好，重复升级 _columnExists 短路 no-op）。
            if (await _tableExists('media_collections') &&
                !await _columnExists(
                    'media_collections', 'subtitle_language')) {
              await m.addColumn(
                  mediaCollections, mediaCollections.subtitleLanguage);
            }
            if (await _tableExists('media_collections') &&
                !await _columnExists(
                    'media_collections', 'subtitle_release_group')) {
              await m.addColumn(
                  mediaCollections, mediaCollections.subtitleReleaseGroup);
            }
          }
          if (from < 92) {
            // v92（统计域根本性重构）：学习统计唯一事实表 study_segments +
            // 按媒体身份的删除墓碑 study_segment_tombstones（表注释见 tables.dart）。
            //
            // 无损：纯新增两表，旧四张投影表（reading_statistics / video_watch_statistics
            // / reading_hourly_logs / video_hourly_logs）与 activity_events **原样保留、
            // 冻结为 legacy**——不迁移、不改写、不删。读取侧并集 legacy + 新表；写入面
            // 自本版起只写新表。不迁移的理由：日汇总行没 hour、小时行没 title，任何
            // 合成都得丢一维或双计（Never break userspace = 老数字一个字节不动）。
            //
            // 幂等：fresh DB 由 onCreate 的 createAll 建好；重复升级被 _tableExists
            // 短路 no-op；索引走 _ensureIndexes（IF NOT EXISTS）。
            if (!await _tableExists('study_segments')) {
              await m.createTable(studySegments);
            }
            if (!await _tableExists('study_segment_tombstones')) {
              await m.createTable(studySegmentTombstones);
            }
            await _ensureIndexes();
          }
          if (from < 93) {
            // v93（网页播放器自动制卡队列）：新表 web_mine_queue，设备本地、无 FK、
            // 无索引（队列量级为几十行）。守卫幂等（fresh DB 由 onCreate 建好）。
            if (!await _tableExists('web_mine_queue')) {
              await m.createTable(webMineQueue);
            }
          }
          if (from < 94) {
            // v94（刮削重设计 P1，BUG-2003）：video_download_jobs /
            // video_download_subscriptions 各加 identity_json——发现页完整身份
            // （原名/别名/全部外部 id）的 JSON 快照，让刮削与字幕不再从
            // 「显示名 + 单 id」的残渣里重新猜身份。无损：nullable 无 default，
            // 旧行全 NULL = 走旧行为。守卫幂等（fresh DB 由 onCreate 建好）。
            if (await _tableExists('video_download_jobs') &&
                !await _columnExists('video_download_jobs', 'identity_json')) {
              await m.addColumn(
                  videoDownloadJobs, videoDownloadJobs.identityJson);
            }
            if (await _tableExists('video_download_subscriptions') &&
                !await _columnExists(
                    'video_download_subscriptions', 'identity_json')) {
              await m.addColumn(videoDownloadSubscriptions,
                  videoDownloadSubscriptions.identityJson);
            }
          }
          if (from < 95) {
            // v95（库页/详情页技术规格标注）：新表 video_file_specs，缓存 ffprobe 探到的
            // 分辨率 / HDR 色彩标签 / 编码 / 色深 / 帧率 / 音轨 / 字幕轨。身份键是**文件
            // 路径**而非 bookUid——一个 video_books 行可能是多集播放列表，各集规格不同
            // （详见 tables.dart 的表注释）。
            // 无损：纯新增表，不动任何既有表和列；旧库升级后表为空 = 规格未探，UI 不显示
            // 角标，与升级前行为一致，探测队列会按需回填。
            // 幂等：fresh DB 由 onCreate 的 createAll 建好；重复升级被 `_tableExists` 短路。
            if (!await _tableExists('video_file_specs')) {
              await m.createTable(videoFileSpecs);
            }
          }
          if (from < 96) {
            // v96（BUG-2158 词典折叠三态）：dictionary_metadata 加
            // expanded_languages_json，给「用户显式展开」一个可持久化的态。
            //
            // 为什么只能开新台阶而不是塞进 from < 95：已发布的版本号是只读的
            // （v88 那步的注释里记着这条教训的实测代价）——已经跑过 95 的库不会再
            // 执行 `from < 95`，那批用户的写路径会直接撞 no such column。
            //
            // 无损：列有 default '[]' → 旧库既有行升级后全是空名单 = 全部「继承」
            // = 逐字节保持 v96 前的折叠行为（Never break userspace）。
            // 幂等：fresh DB 由 onCreate 的 createAll 建好；重复升级被
            // _columnExists 短路。
            await _ensureDictionaryExpandedLanguagesColumn(m);
          }
          if (from < 97) {
            // v97（schema 漂移修补，BUG-2162）：真实用户库 user_version 已是 95，却缺
            // v52 / v57 / v87 / v88 四级台阶的产物——epub_books / dictionary_metadata /
            // video_books / srt_books / galgames 的 language 系列列、media_collections 的
            // audio_track_id + subtitle_delay_ms、两张墓碑表的 removed_at 没改名
            // deleted_at。这个库的版本号是在另一条并行迁移史上被写到那些数字之上的
            // （本仓与上游的 schema 号曾重号），`from < N` 对它永远不会再进；表现是
            // 导入书 INSERT epub_books(... language) 直接 no such column，整个导入失败。
            // 已发布的版本号只读（v88 注释的规则），唯一修法是开新台阶把那几步**幂等
            // 重放**一次：每条都有 _columnExists 守卫，正常升级路径上来的库全部短路
            // no-op；漂移库补齐后与 fresh 库同形。多余列（漂移库里另一条史留下的
            // video_download_jobs.episode 等）不动——SQLite 多一列无害，删列有丢数据风险。
            await _replayColumnStepsForDriftedSchema(m);
          }
          if (from < 98) {
            if (await _tableExists('video_books') &&
                !await _columnExists('video_books', 'video_grouping_mode')) {
              await m.addColumn(videoBooks, videoBooks.videoGroupingMode);
            }
            // 来源分组偏好独立于网络配置；已有来源继续按作品识别。
            if (await _tableExists('media_sources') &&
                !await _columnExists('media_sources', 'video_grouping_mode')) {
              await m.addColumn(mediaSources, mediaSources.videoGroupingMode);
            }
            if (await _tableExists('media_collections') &&
                !await _columnExists('media_collections', 'source_folder_path')) {
              await m.addColumn(
                  mediaCollections, mediaCollections.sourceFolderPath);
            }
          }
          if (from < 99) {
            // 刮削 C 二期：来源级资料语言覆盖 + 作品级字段锁。两列都是可空
            // 文本，NULL = 沿用既有行为（跟随全局 locale / 无锁），存量库无需回填。
            if (await _tableExists('video_source_scrape_settings') &&
                !await _columnExists(
                    'video_source_scrape_settings', 'metadata_locale')) {
              await m.addColumn(videoSourceScrapeSettings,
                  videoSourceScrapeSettings.metadataLocale);
            }
            if (await _tableExists('video_metadata_works') &&
                !await _columnExists('video_metadata_works', 'locked_fields')) {
              await m.addColumn(
                  videoMetadataWorks, videoMetadataWorks.lockedFields);
            }
          }
          if (from < 100) {
            // v100（语言级 Profile 绑定）：新表 language_profiles，把「这种内容语言用
            // 哪个 Profile」补进 Profile 的自动解析链（book > language > mediaType >
            // active）。与 v95 同款的纯新增表范式。
            //
            // 无损：旧库升级后表为空 = 没有任何语言绑定 = 解析链在语言这一级恒空转、
            // 直接落到 mediaType，与升级前逐字节一致（Never break userspace）。
            // 幂等：fresh DB 由 onCreate 的 createAll 建好；重复升级被 _tableExists 短路。
            if (!await _tableExists('language_profiles')) {
              await m.createTable(languageProfiles);
            }
            // 索引与建表同步内联：`_ensureIndexes` 只在 onCreate 与个别迁移步里跑，
            // 升级路径不会自动补上（与 v9 同款处理）。
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_language_profiles_profile '
              'ON language_profiles (profile_id)',
            );
          }
          if (from < 101) {
            // v101（词典改名）：dictionary_metadata 加 display_name——用户给词典
            // 起的显示名。真名 `name` 是主键 + 磁盘目录名 + 引擎装载路径 + 一串
            // 外键（CSS map key / 样式规则 / data-dictionary 选择器 / 媒体 URL /
            // Anki token / 同步资产名），冻结不动，只加显示层覆盖（见 tables.dart
            // 该列的注释）。
            //
            // 无损：nullable 无 default → 旧库既有行全 NULL = 没改过名 = 显示真名
            // = 逐字节保留 v101 前的渲染。守卫幂等（fresh DB 由 onCreate 建好，
            // 重复升级 _columnExists 短路 no-op）。
            if (await _tableExists('dictionary_metadata') &&
                !await _columnExists('dictionary_metadata', 'display_name')) {
              await m.addColumn(
                  dictionaryMetadata, dictionaryMetadata.displayName);
            }
          }
          if (from < 102) {
            // v102（统一更新提醒）：新表 update_feed_entries，四个域（番剧新集 /
            // 漫画新章 / 漫画扩展新版 / app 新版）投递到同一条事件流。与 v95、v100
            // 同款的纯新增表范式。
            //
            // 无损：旧库升级后表为空 = 一条提醒都没有 = 红点恒 0、更新页空列表，
            // 与升级前逐字节一致；已有的首页「已更新未看」行是独立现算逻辑，不读本表。
            // 幂等：fresh DB 由 onCreate 的 createAll 建好；重复升级被 _tableExists 短路。
            if (!await _tableExists('update_feed_entries')) {
              await m.createTable(updateFeedEntries);
            }
            // 索引与建表同步内联（`_ensureIndexes` 不覆盖升级路径，见 v100 步）。
            // 未读计数与按域分组是仅有的两种读法，一条复合索引兜住。
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_update_feed_kind_seen '
              'ON update_feed_entries (kind, seen_at)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_update_feed_discovered '
              'ON update_feed_entries (discovered_at)',
            );
          }
          if (from < 103) {
            // v103（漫画先下载再读）：新表 manga_download_jobs——在线章节 /
            // mokuro.moe 卷的持久化下载队列。与 v100、v102 同款的纯新增表范式。
            //
            // 无损：旧库升级后表为空 = 一个任务都没有 = 下载 worker 空转，与升级前
            // 逐字节一致；在线阅读改走本地目录是 B2 阶段的事，本步只加表。
            // 幂等：fresh DB 由 onCreate 的 createAll 建好；重复升级被 _tableExists 短路。
            if (!await _tableExists('manga_download_jobs')) {
              await m.createTable(mangaDownloadJobs);
            }
            // 索引与建表同步内联（升级路径不会自动补上）；fresh 库由
            // `_ensureIndexes` 建同名索引，两处 SQL 必须逐字一致。
            await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS idx_manga_download_jobs_identity '
              'ON manga_download_jobs (kind, book_key, chapter_key)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_manga_download_jobs_status_created '
              'ON manga_download_jobs (status, created_at)',
            );
          }
          if (from < 104) {
            if (!await _tableExists('collection_book_aliases')) {
              await m.createTable(collectionBookAliases);
            }
          }
          if (from < 105) {
            // v105（统计按 Profile 隔离）：`study_segments` / `galgame_sessions`
            // 加分区列 profile_id；`study_segment_tombstones` 主键并入 profile_id
            // （PK 变 = 重建表）。存量行全部归到升级那一刻激活的 Profile（没有
            // 激活的取最早建的；一个都没有就建 'Default'——升级前的历史必须有
            // 归属，否则新 Profile 一建，旧统计对谁都不可见）。
            //
            // legacy 四张投影表 + activity_events 不加列（冻结只读）：同一 Profile
            // 记进偏好 `stats_legacy_profile_id`，读取面只对它露出 legacy 行。
            final int owner = await _statOwnerProfileForV105();
            if (await _tableExists('study_segments') &&
                !await _columnExists('study_segments', 'profile_id')) {
              await m.addColumn(studySegments, studySegments.profileId);
              await customStatement(
                'UPDATE study_segments SET profile_id = ?',
                <Object>[owner],
              );
            }
            if (await _tableExists('galgame_sessions') &&
                !await _columnExists('galgame_sessions', 'profile_id')) {
              await m.addColumn(galgameSessions, galgameSessions.profileId);
              await customStatement(
                'UPDATE galgame_sessions SET profile_id = ?',
                <Object>[owner],
              );
            }
            if (await _tableExists('study_segment_tombstones') &&
                !await _columnExists('study_segment_tombstones', 'profile_id')) {
              await customStatement('''
              CREATE TABLE study_segment_tombstones_v105 (
                profile_id INTEGER NOT NULL DEFAULT 0,
                media_kind TEXT NOT NULL,
                media_key TEXT NOT NULL,
                deleted_at INTEGER NOT NULL,
                PRIMARY KEY (profile_id, media_kind, media_key))''');
              await customStatement(
                'INSERT OR IGNORE INTO study_segment_tombstones_v105 '
                '(profile_id, media_kind, media_key, deleted_at) '
                'SELECT ?, media_kind, media_key, deleted_at '
                'FROM study_segment_tombstones',
                <Object>[owner],
              );
              await customStatement('DROP TABLE study_segment_tombstones');
              await customStatement(
                'ALTER TABLE study_segment_tombstones_v105 '
                'RENAME TO study_segment_tombstones',
              );
            }
            // 分区索引与加列同步内联（升级路径不跑 _ensureIndexes）。表存在性
            // 守卫与 _ensureIndexes 同理：部分迁移的老库可能缺这两张表。
            if (await _tableExists('study_segments')) {
              await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_study_segments_profile_date '
                'ON study_segments (profile_id, date_key)',
              );
            }
            if (await _tableExists('galgame_sessions')) {
              await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_galgame_sessions_profile_date '
                'ON galgame_sessions (profile_id, date_key)',
              );
            }
            if (owner > 0 && await _tableExists('preferences')) {
              await customStatement(
                'INSERT OR REPLACE INTO preferences ("key", "value", updated_at) '
                'VALUES (?, ?, ?)',
                <Object>[
                  kStatLegacyProfileIdPrefKey,
                  owner.toString(),
                  DateTime.now().millisecondsSinceEpoch,
                ],
              );
            }
          }
          if (from < 106) {
            // v106（AniDB 文件级身份持久化）：新表 anidb_file_identities，与
            // v103 / v104 同款的纯新增表范式。无损：旧库升级后表为空，下一次
            // 刮削按需回填。幂等：fresh DB 由 onCreate 的 createAll 建好；重复
            // 升级被 _tableExists 短路。
            if (!await _tableExists('anidb_file_identities')) {
              await m.createTable(anidbFileIdentities);
            }
            // 索引与建表同步内联（升级路径不会自动补上）；fresh 库由
            // `_ensureIndexes` 建同名索引，两处 SQL 必须逐字一致。
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_anidb_file_identities_path '
              'ON anidb_file_identities (file_path, file_size)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_anidb_file_identities_anime '
              'ON anidb_file_identities (anidb_anime_id)',
            );
          }
          if (from < 107) {
            // v107（视频在线源扩展）：Mihon 扩展三张表加 media_kind 列，把
            // Aniyomi 视频扩展与漫画扩展分片在同一套表里（仓库索引格式同源、
            // 宿主运行时同一个）。存量行全是漫画，列默认值 'manga' 即历史事实，
            // 无需回填。幂等：fresh 库由 createAll 带列建表；重复升级被
            // _columnExists 短路；部分表形态的种子库先查 _tableExists。
            if (await _tableExists('manga_extension_stores') &&
                !await _columnExists('manga_extension_stores', 'media_kind')) {
              await m.addColumn(
                mangaExtensionStores,
                mangaExtensionStores.mediaKind,
              );
            }
            if (await _tableExists('manga_extensions') &&
                !await _columnExists('manga_extensions', 'media_kind')) {
              await m.addColumn(mangaExtensions, mangaExtensions.mediaKind);
            }
            if (await _tableExists('manga_online_sources') &&
                !await _columnExists('manga_online_sources', 'media_kind')) {
              await m.addColumn(
                mangaOnlineSources,
                mangaOnlineSources.mediaKind,
              );
            }
          }
          if (from < 108) {
            // v108（AniDB 对齐 Shoko）：anidb_file_identities 加 miss_attempts，
            // 记 AniDB FILE 回 320「未收录」的连续复查次数（对齐 Shoko
            // MaxAutoScanAttemptsPerFile 上限，识别成功时归零）。存量行默认 0
            // 即「尚未计数」，无需回填。幂等：fresh 库由 createAll 带列建表；
            // 重复升级被 _columnExists 短路；缺表的种子库先查 _tableExists。
            if (await _tableExists('anidb_file_identities') &&
                !await _columnExists('anidb_file_identities', 'miss_attempts')) {
              await m.addColumn(
                anidbFileIdentities,
                anidbFileIdentities.missAttempts,
              );
            }
          }
          if (from < 109) {
            // v109（AniDB 对齐 Shoko，集级）：anidb_file_identities 加
            // episode_aired_at（UDP EPISODE 的集播出日，供 AniDB 集 → TMDB 集按
            // 「播出日 + 标题」逐集链接；存量行 null，sweep 时补问一次回填），
            // 以及 FILE 掩码扩展后多出的 other_episodes（一文件多集）/
            // is_deprecated / file_state（CRC 正误、文件版本）。存量行取默认值即
            // 「未知」，下次识别时随 FILE 应答一起落。幂等守卫同 v108。
            if (await _tableExists('anidb_file_identities')) {
              if (!await _columnExists(
                  'anidb_file_identities', 'episode_aired_at')) {
                await m.addColumn(
                  anidbFileIdentities,
                  anidbFileIdentities.episodeAiredAt,
                );
              }
              if (!await _columnExists(
                  'anidb_file_identities', 'other_episodes')) {
                await m.addColumn(
                  anidbFileIdentities,
                  anidbFileIdentities.otherEpisodes,
                );
              }
              if (!await _columnExists(
                  'anidb_file_identities', 'is_deprecated')) {
                await m.addColumn(
                  anidbFileIdentities,
                  anidbFileIdentities.isDeprecated,
                );
              }
              if (!await _columnExists('anidb_file_identities', 'file_state')) {
                await m.addColumn(
                  anidbFileIdentities,
                  anidbFileIdentities.fileState,
                );
              }
            }
            // 分集行带上绑定文件的 AniDB 集身份（eid / 原生集号 / TMDB 链接评级），
            // Shoko 的 CrossRef_AniDB_TMDB_Episode 在本仓的落点；存量行 null，
            // 下次刮削时随绑定一起写。
            if (await _tableExists('video_metadata_episodes')) {
              if (!await _columnExists(
                  'video_metadata_episodes', 'anidb_episode_id')) {
                await m.addColumn(
                  videoMetadataEpisodes,
                  videoMetadataEpisodes.anidbEpisodeId,
                );
              }
              if (!await _columnExists(
                  'video_metadata_episodes', 'anidb_episode_number')) {
                await m.addColumn(
                  videoMetadataEpisodes,
                  videoMetadataEpisodes.anidbEpisodeNumber,
                );
              }
              if (!await _columnExists(
                  'video_metadata_episodes', 'anidb_match_rating')) {
                await m.addColumn(
                  videoMetadataEpisodes,
                  videoMetadataEpisodes.anidbMatchRating,
                );
              }
            }
          }
          if (from < 110) {
            // v110：video_metadata_episodes.book_uid 去掉列级 UNIQUE——AniDB
            // FILE 给出的「一文件多集」（`01-02` 合集文件）要绑到两条分集行，
            // Shoko `CrossRef_File_Episode` 一文件多集。列级 UNIQUE 是内联约束、
            // SQLite 不能单独 DROP，走 alterTable 按当前 Dart 定义重建 + 按列名拷
            // 贝（v67 先例），`id` 原值保留所以四张以 id 引用的子表（identities /
            // credits / images CASCADE、sidecar SET NULL）不悬空；FK OFF/ON 夹住
            // 重建（v57 先例），否则 DROP 旧表会级联清空子表。幂等守卫：只在
            // 自动唯一索引仍只覆盖 book_uid 时才重建，mid-ladder 由 createTable
            // fresh 建出的表已是新 shape 直接短路。
            if (await _tableExists('video_metadata_episodes') &&
                await _hasUniqueIndexOnColumn(
                    'video_metadata_episodes', 'book_uid')) {
              final bool foreignKeysWereOn = await _foreignKeysEnabled();
              await customStatement('PRAGMA foreign_keys = OFF');
              try {
                await m.alterTable(TableMigration(videoMetadataEpisodes));
                if (await _tableExists('video_metadata_seasons') &&
                    await _tableExists('video_books')) {
                  final List<QueryRow> violations = await customSelect(
                          'PRAGMA foreign_key_check(video_metadata_episodes)')
                      .get();
                  if (violations.isNotEmpty) {
                    throw StateError(
                        'v110 migration left ${violations.length} FK '
                        'violations in video_metadata_episodes');
                  }
                }
              } finally {
                if (foreignKeysWereOn) {
                  await customStatement('PRAGMA foreign_keys = ON');
                }
              }
            }
            await _ensureIndexes();
          }
          if (from < 111) {
            // v111：① anidb_file_identities.anime_type——FILE amask 取回的 AniDB
            // 动画类型，Shoko 的作品形态来源（存量行 ''，下次 FILE 命中时补）；
            // ② video_episode_binding_overrides——用户手动钉死的文件 → 季集绑定
            // （Shoko UserVerified），刮削时最高优先级、每次重刮都保留。
            if (await _tableExists('anidb_file_identities') &&
                !await _columnExists('anidb_file_identities', 'anime_type')) {
              await m.addColumn(
                anidbFileIdentities,
                anidbFileIdentities.animeType,
              );
            }
            if (!await _tableExists('video_episode_binding_overrides')) {
              await m.createTable(videoEpisodeBindingOverrides);
            }
          }
          if (from < 112) {
            // v112：manga_reader_overrides——漫画阅读器的每作品稀疏覆盖（Mihon
            // 对齐的阅读模式/缩放/裁边等），全局默认仍落 preferences。存量的
            // epub_books.manga_reading_mode 不改写，按书搬成一条稀疏覆盖，旧列
            // 留给旧版本读。幂等守卫同 v108。
            if (!await _tableExists('manga_reader_overrides')) {
              await m.createTable(mangaReaderOverrides);
            }
            if (await _tableExists('epub_books') &&
                await _columnExists('epub_books', 'manga_reading_mode') &&
                await _columnExists('epub_books', 'uid')) {
              final List<QueryRow> legacy = await customSelect(
                "SELECT uid, manga_reading_mode FROM epub_books "
                "WHERE uid != '' AND format = 'manga'",
              ).get();
              for (final QueryRow row in legacy) {
                final String? mode =
                    row.readNullable<String>('manga_reading_mode');
                // `manga_reading_mode` 为 NULL / 空 = 这本书从没被单独设过，语义是
                // 「跟随全局」。给它写一行 `{'autoMode': true}` 等于把每一本存量漫画
                // 都钉成自动判定：此后用户改全局阅读模式，对全部存量书永久不再生效。
                // 而且覆盖表本该是**稀疏**的（PR 说明也这么写），逐本写行会让每本书
                // 各多一次 sidecar 资产上传与一条互联 wire 条目。
                if (mode != 'spread' && mode != 'webtoon') continue;
                await into(mangaReaderOverrides).insert(
                  MangaReaderOverridesCompanion.insert(
                    bookUid: row.read<String>('uid'),
                    overridesJson: Value(
                      jsonEncode(<String, Object?>{
                        'autoMode': false,
                        'mode': mode,
                      }),
                    ),
                    updatedAt: 0,
                  ),
                  mode: InsertMode.insertOrIgnore,
                );
              }
            }
          }
          if (from < 113) {
            // v113：galgame_sessions.game_id 去掉 `REFERENCES galgames ON DELETE
            // CASCADE`（改逻辑外键），并加 game_title 快照列。此前从库移除游戏会经
            // cascade 删光它在**所有 Profile** 下的游玩会话——不勾「同时删除统计数据」
            // 也丢游玩时长。内联 FK 约束 SQLite 不能单独 DROP，走 alterTable 按当前
            // Dart 定义重建 + 按列名拷贝（v110 先例），`id` 原值保留，表上既有索引
            // 由 alterTable 按 sqlite_master 原文重建；存量会话的游戏都还在库里（旧
            // cascade 保证没有孤儿），game_title 取默认空串即可。
            // 没有表引用 galgame_sessions，FK OFF/ON 夹住只是沿用重建惯例。幂等
            // 守卫：只在还挂着 FK 或缺 game_title 时重建，mid-ladder 由 createTable
            // fresh 建出的表已是新 shape 直接短路。
            if (await _tableExists('galgame_sessions') &&
                (await _hasForeignKeys('galgame_sessions') ||
                    !await _columnExists('galgame_sessions', 'game_title'))) {
              final bool foreignKeysWereOn = await _foreignKeysEnabled();
              await customStatement('PRAGMA foreign_keys = OFF');
              try {
                await m.alterTable(TableMigration(
                  galgameSessions,
                  newColumns: [galgameSessions.gameTitle],
                ));
              } finally {
                if (foreignKeysWereOn) {
                  await customStatement('PRAGMA foreign_keys = ON');
                }
              }
            }
          }
          if (from < 114) {
            // v114：favorite_words 加收藏上下文（原句 + 定位锚点四列）。存量行
            // 取默认 '' / null——旧收藏本来就没记，不回填。幂等守卫同 v111。
            if (await _tableExists('favorite_words')) {
              if (!await _columnExists('favorite_words', 'sentence')) {
                await m.addColumn(favoriteWords, favoriteWords.sentence);
              }
              if (!await _columnExists('favorite_words', 'section_index')) {
                await m.addColumn(favoriteWords, favoriteWords.sectionIndex);
              }
              if (!await _columnExists('favorite_words', 'norm_char_offset')) {
                await m.addColumn(favoriteWords, favoriteWords.normCharOffset);
              }
              if (!await _columnExists('favorite_words', 'norm_char_length')) {
                await m.addColumn(favoriteWords, favoriteWords.normCharLength);
              }
            }
          }
          if (from < 115) {
            // v115（排行榜的两个本地事实；原定 v114，被并行合入的收藏上下文占用后顺延）：
            // ① epub_books.isbn——OPF dc:identifier 规范化后的 ISBN-13。存量书不在
            //   迁移里读文件（慢且解压目录可能不在），由引擎侧 backfillEpubIsbns
            //   只读 OPF 回填；这里只加列。
            // ② galgames.completed_at——进入「玩过」(play_status=2) 的毫秒戳。存量
            //   「玩过」取该游戏最后一次游玩会话的 end_ms（跨全部 Profile；v113 起
            //   会话不随游戏删，但此处按 game_id 关联的只会是仍在库的游戏）；一条
            //   会话都没有的留 NULL（= 日期未知）。
            // 幂等守卫：mid-ladder 由 createTable 按当前 Dart 定义建出的表已带列。
            if (await _tableExists('epub_books') &&
                !await _columnExists('epub_books', 'isbn')) {
              await m.addColumn(epubBooks, epubBooks.isbn);
            }
            if (await _tableExists('galgames') &&
                !await _columnExists('galgames', 'completed_at')) {
              await m.addColumn(galgames, galgames.completedAt);
            }
            if (await _tableExists('galgames') &&
                await _tableExists('galgame_sessions')) {
              await customStatement(
                'UPDATE galgames SET completed_at = '
                '(SELECT MAX(s.end_ms) FROM galgame_sessions AS s '
                'WHERE s.game_id = galgames.id) '
                'WHERE play_status = 2 AND completed_at IS NULL',
              );
            }
          }
          if (from < 116) {
            // v116（待发制卡队列；原定 v114，被并行合入的收藏上下文 v114 / 排行榜 v115
            // 占用后顺延）：设备端 pending_mine_queue（后端不可达/批量模式先入队
            // 稍后补发；载荷在 <support>/pending_mine_queue/<id>.json）。设备本地、
            // 无 FK；fresh DB 已由 onCreate 的 createAll 建好，_tableExists 守卫幂等。
            if (!await _tableExists('pending_mine_queue')) {
              await m.createTable(pendingMineQueue);
            }
          }
          if (from < 117) {
            // v117（Fushi SRS，docs/specs/2026-10-14-fushi-srs-design.md）：
            // profiles.uid（全局身份，存量行生成 UUIDv7）+ 八张 srs_* 表（三张同步事件表、
            // 不认识事件表、本机元信息 / 状态、两张可重建缓存）。全部幂等守卫。
            // profiles 表在迁移阶梯上可能不存在（老库在建它的那一步之后才补 / 合成库），
            // 与其它加列步同形：表不在就跳过加列 / 回填 / 索引，不得炸掉整条迁移。
            if (await _tableExists('profiles')) {
              if (!await _columnExists('profiles', 'uid')) {
                await m.addColumn(profiles, profiles.uid);
              }
              await _backfillProfileUids();
              await _ensureProfileUidIndex();
            }
            // srs_* 表从 2026-10-23 起归 Rust 独占的 srs.db（docs/specs/2026-10-23-srs-rust-store.md），
            // 不再在 Drift 里声明；老库仍按当年的形状建出来，由 SrsDbStore 打开前的一次性搬迁
            // （fushi_engine srs_legacy_store_migration.dart）搬走后删除。
            await _createLegacySrsTables(kLegacySrsV117Tables);
            await _ensureSrsIndexes();
          }
          if (from < 118) {
            // v118：epub_books / srt_books / video_books 各加 local_added_at——「本机
            // 开始拥有该条目的时刻」，从 imported_at（原始入库时刻）里拆出来。此前
            // 一列两义：BUG-3452 / BUG-2463 让互联下载把 imported_at 写成对端入库
            // 时刻（展示 / 排序要的），而删除墓碑仲裁与首页「最近添加」要的是本机
            // 落地时刻，两者在下载行上不再相等。
            //
            // 回填 = imported_at：存量行里两者本就同义（本地导入 / 云同步拉下都写
            // 当时 now）。唯一例外是 BUG-3452（epub）/ BUG-2463（视频）合入后经互联
            // 下载的少量行——它们的 imported_at 已是对端时刻，库里没有任何列还记得
            // 本机落地时刻，无从区分，只能同样按 imported_at 回填（效果与升级前一致，
            // 不会更糟）；此后新落地的行由写入单点记真实的本机时刻。
            //
            // `WHERE local_added_at IS NULL` 让本步幂等，也覆盖迁移阶梯上按当前 Dart
            // 定义 createTable / 重建、列已在但值为空的表。表在阶梯上可能不存在
            // （合成库），与其它加列步同形跳过。
            // 三张表逐条写 addColumn（不收进循环）：schema doc 守卫按 `m.addColumn(x,
            // x.y)` 字面形态认列的落地版本。
            if (await _tableExists('epub_books')) {
              if (!await _columnExists('epub_books', 'local_added_at')) {
                await m.addColumn(epubBooks, epubBooks.localAddedAt);
              }
              await _backfillLocalAddedAt('epub_books');
            }
            if (await _tableExists('srt_books')) {
              if (!await _columnExists('srt_books', 'local_added_at')) {
                await m.addColumn(srtBooks, srtBooks.localAddedAt);
              }
              await _backfillLocalAddedAt('srt_books');
            }
            if (await _tableExists('video_books')) {
              if (!await _columnExists('video_books', 'local_added_at')) {
                await m.addColumn(videoBooks, videoBooks.localAddedAt);
              }
              await _backfillLocalAddedAt('video_books');
            }
          }
          if (from < 119) {
            // v119（视频字幕 AI 校对，docs/specs/2026-10-19-video-asr-llm-subtitle-
            // pipeline.md 第 3 节 S0）：
            // ① video_metadata_characters.original_name——角色日文原名（MAL
            //   name_kanji）。存量行留 NULL，下次刮削补上（upsert 只补空）。
            // ② video_subtitle_glossaries——作品级专名表（JSON + 来源指纹 +
            //   userEditedAt）。
            // 幂等守卫：表在阶梯上可能不存在（合成库）就跳过加列；mid-ladder 由
            // createTable 按当前 Dart 定义建出的表已带列。
            if (await _tableExists('video_metadata_characters') &&
                !await _columnExists(
                  'video_metadata_characters',
                  'original_name',
                )) {
              await m.addColumn(
                  videoMetadataCharacters, videoMetadataCharacters.originalName);
            }
            if (!await _tableExists('video_subtitle_glossaries')) {
              await m.createTable(videoSubtitleGlossaries);
            }
          }
          if (from < 120) {
            // v120（BUG-3543）：srs_field_edits 加前身链接的部分覆盖索引
            // idx_srs_field_edits_history_from（见 _ensureSrsIndexes）。只加索引、不动数据；
            // 全部 IF NOT EXISTS，幂等。v117 之前的库在 v117 步已建表连同全部索引，这里再
            // 跑一次也无害；表在阶梯上不存在（合成库）则跳过。
            if (await _tableExists('srs_field_edits')) {
              await _ensureSrsIndexes();
            }
          }
          if (from < 121) {
            // v121（Fushi SRS 多目录同步；原定 v119 / v120，被并行合入的视频字幕 AI 校对与
            // SRS 批量修复的索引步占用后顺延）：
            // srs_sent_batches——本机已冻结批次的留存，同一批次逐字节相同地传到每个同步目录
            // （云盘 / 互联 host / 本机 host 目录），到最近同步过的目录都确认为止。设备本地、
            // 不进备份、无外键；存量库没有留存可迁（旧版本冻结中的批次由 SrsDbStore 读本机
            // 状态时搬进来）。
            if (await _tableExists('srs_entities')) {
              await _createLegacySrsTables(const <String>['srs_sent_batches']);
            }
          }
          if (from < 122) {
            // v122：作品级「私密」标记表 media_privacy_flags（不上传排行榜、不推
            // Bangumi）。纯新表、不动数据；幂等守卫同 v119。
            if (!await _tableExists('media_privacy_flags')) {
              await m.createTable(mediaPrivacyFlags);
            }
          }
          if (from < 123) {
            // v123：srs_cards_cache.new_position——新卡出卡位置（卡片修改记录 `newPos`
            // 的生效值，「按词频重排新卡」写它）。这里只加列、留 NULL：旧版本设备可能已从
            // 对端收下 `newPos` 修改记录，那些卡由 SrsDbStore 打开时按本机缓存版本定向重算
            // （fushi_engine `SrsDbStore._upgradeCaches`）。幂等守卫同 v119。
            if (await _tableExists('srs_cards_cache') &&
                !await _columnExists('srs_cards_cache', 'new_position')) {
              await customStatement(
                'ALTER TABLE srs_cards_cache ADD COLUMN new_position INTEGER NULL',
              );
            }
          }
          if (from < 124) {
            // v124（AI 整理库，docs/specs/2026-10-20-ai-library-organize-design.md §5）：
            // ① media_collections.origin / organize_key / organize_aliases——合集由谁建
            //   归谁管 + 整理分组身份。存量行一律 `user`（分不清的宁可当用户的，整理器
            //   永不改它），目录自动合集（source_folder_path 非空）回填 `folder`。
            // ② collection_member_tombstones.organize_key / organize_merged——合集级删除
            //   哨兵上的分组键与「是被并掉还是用户删的」。存量 NULL / false。
            // ③ library_organize_runs / library_organize_changes——本机整理记录（设备本地）。
            // 幂等守卫同 v119。
            if (await _tableExists('media_collections')) {
              if (!await _columnExists('media_collections', 'origin')) {
                await m.addColumn(mediaCollections, mediaCollections.origin);
                await customStatement(
                  "UPDATE media_collections SET origin = 'folder' "
                  'WHERE source_folder_path IS NOT NULL',
                );
              }
              if (!await _columnExists('media_collections', 'organize_key')) {
                await m.addColumn(
                    mediaCollections, mediaCollections.organizeKey);
              }
              if (!await _columnExists(
                  'media_collections', 'organize_aliases')) {
                await m.addColumn(
                    mediaCollections, mediaCollections.organizeAliases);
              }
            }
            if (await _tableExists('collection_member_tombstones') &&
                !await _columnExists(
                    'collection_member_tombstones', 'organize_key')) {
              await m.addColumn(collectionMemberTombstones,
                  collectionMemberTombstones.organizeKey);
            }
            if (await _tableExists('collection_member_tombstones') &&
                !await _columnExists(
                    'collection_member_tombstones', 'organize_merged')) {
              await m.addColumn(collectionMemberTombstones,
                  collectionMemberTombstones.organizeMerged);
            }
            if (!await _tableExists('library_organize_runs')) {
              await m.createTable(libraryOrganizeRuns);
            }
            if (!await _tableExists('library_organize_changes')) {
              await m.createTable(libraryOrganizeChanges);
            }
          }
          // v125–v131 是两条并行迁移史争用过的版本号（同 BUG-2335 / v97 的教训）：
          // develop 用 v125–v128 给了 SRS 索引 / 墓碑 published_at / 书签列 / 内置浏览器
          // 五张表；音乐 / 作品图谱分支（PR #2534）合入前在自己的阶梯上把 v125–v131 用给了
          // media_links / 音乐表 / 主题曲区间 / mined_sentences 定位列，合入时整体后移到
          // v129–v135。同一个库可能在两条阶梯之间来回被打开过，user_version 落在 125–131
          // 时无法判断走的是哪一条、缺的是哪一侧（develop 的 125–128 产物，或分支在
          // 128→131 时跳过的 media_links / 音乐表 / 主题曲区间）。所以这一段一律按
          // `from < 132` 补跑两侧的全部产物——每步都先判表 / 列 / 索引是否已存在，对按本
          // 阶梯正常走过来的库是空操作；mined_sentences 定位列由下面的 v132 补。
          if (from < 132) {
            // v125–v128，四步全部幂等，收在 _ensureV125ToV128Artifacts。
            await _ensureV125ToV128Artifacts(m);
          }
          if (from < 132) {
            // v129（跨模块作品图谱，docs/specs/2026-10-24-cross-media-links.md）：
            // media_links——本地条目之间的连接（手动连接 + 推断建议 + 否决墓碑），
            // 随互联同步与备份走。幂等守卫同 v119。
            if (!await _tableExists('media_links')) {
              await m.createTable(mediaLinks);
            }
          }
          if (from < 132) {
            // v130（音乐模块 P0，docs/specs/2026-10-23-music-module-design.md §10）：
            // 曲库目录 / 署名 / 歌词缓存 / MV 绑定 / 光盘来源 / 歌单 / 播放流十张新表。
            // 纯建表、不动既有数据；幂等守卫同 v119。
            for (final TableInfo<Table, Object?> table in <TableInfo<Table, Object?>>[
              musicTracks,
              musicAlbums,
              musicArtists,
              musicTrackCredits,
              musicLyrics,
              musicVideos,
              musicDiscSources,
              musicPlaylists,
              musicPlaylistEntries,
              musicPlayEvents,
            ]) {
              if (!await _tableExists(table.actualTableName)) {
                await m.createTable(table);
              }
            }
            await _ensureMusicIndexes();
          }
          if (from < 132) {
            // v131（作品图谱 L2，docs/specs/2026-10-24-cross-media-links.md §2）：
            // video_theme_song_spans——OP / ED 声纹比对结果的按集缓存（设备本地、纯缓存）。
            // 纯建表；幂等守卫同 v119。
            if (!await _tableExists('video_theme_song_spans')) {
              await m.createTable(videoThemeSongSpans);
            }
          }
          if (from < 132) {
            // v132（卡片「回到出处」，docs/specs/2026-10-24-cross-media-links.md §4）：
            // mined_sentences 加显式定位列 position_ms / duration_ms（视频 / 音乐时间轴）
            // 与 page_index（漫画页）。此前视频来源把 norm_char_offset / norm_char_length
            // 复用成 cue 起点 / 时长毫秒（同一列语义随 source 变）：把 source='video' 的
            // 旧值搬进新列，并清空旧列——旧列从此只表示字符偏移。
            //
            // 清空而不是保留双写：这张表只经本机写入与备份文件流转（不进在线聚合同步
            // wire）；旧备份打开时先走本迁移再 ATTACH 合并，新备份被旧版本拒收
            // （schemaVersion 门），所以不存在仍按旧口径读这一列的消费方。
            // 幂等：列存在即跳过加列；搬迁只动 position_ms 仍为 NULL 的视频行。
            if (await _tableExists('mined_sentences')) {
              for (final GeneratedColumn<Object> column
                  in <GeneratedColumn<Object>>[
                minedSentences.positionMs,
                minedSentences.durationMs,
                minedSentences.pageIndex,
              ]) {
                if (!await _columnExists('mined_sentences', column.name)) {
                  await m.addColumn(minedSentences, column);
                }
              }
              await customStatement(
                'UPDATE mined_sentences SET '
                'position_ms = norm_char_offset, '
                'duration_ms = norm_char_length, '
                'norm_char_offset = NULL, norm_char_length = NULL '
                "WHERE source = 'video' AND position_ms IS NULL "
                'AND (norm_char_offset IS NOT NULL OR norm_char_length IS NOT NULL)',
              );
            }
          }
          if (from < 133) {
            // v133（音乐 P4 刮削，docs/specs/2026-10-23-music-module-design.md §8 / §10）：
            // music_scrape_meta / music_metadata_raw_snapshots / music_locked_fields
            // 三张新表（设备本地）。纯建表、不动既有数据；幂等守卫同 v119。
            for (final TableInfo<Table, Object?> table
                in <TableInfo<Table, Object?>>[
              musicScrapeMeta,
              musicMetadataRawSnapshots,
              musicLockedFields,
            ]) {
              if (!await _tableExists(table.actualTableName)) {
                await m.createTable(table);
              }
            }
          }
          if (from < 134) {
            // v134（作品图谱 L4 跟进，docs/specs/2026-10-24-cross-media-links.md §3）：
            // galgame_text_lines——文本钩子台词的持久副本（「我库里的例句」的游戏来源，
            // 随备份 games 类别走）。纯建表；幂等守卫同 v119。
            if (!await _tableExists('galgame_text_lines')) {
              await m.createTable(galgameTextLines);
            }
          }
          if (from < 135) {
            // v135（作品图谱 L5，docs/specs/2026-10-24-cross-media-links.md §5 / §6）：
            // game_voice_casts（游戏 VNDB 配音表缓存，设备本地）、person_identity_bridges
            // （人物身份桥：Wikidata 桥接缓存 + 用户确认 / 否决的「同一人」）、
            // adaptation_progress_anchors（动画集 ↔ 原作卷 / 章的手动对应点）。
            // 纯建表；幂等守卫同 v119。
            for (final TableInfo<Table, Object?> table
                in <TableInfo<Table, Object?>>[
              gameVoiceCasts,
              personIdentityBridges,
              adaptationProgressAnchors,
            ]) {
              if (!await _tableExists(table.actualTableName)) {
                await m.createTable(table);
              }
            }
          }
          if (from < 136) {
            // v136（AI 助手，docs/specs/2026-10-26-ai-operations-agent-design.md §5.3 /
            // D3 / D5）：ai_agent_sessions（对话存档）/ ai_agent_actions（操作记录）。
            // 设备本地（同 library_organize_*：不同步、不进备份、不分 Profile）。
            // 纯建表 + 索引；幂等守卫同 v119。
            for (final TableInfo<Table, Object?> table
                in <TableInfo<Table, Object?>>[
              aiAgentSessions,
              aiAgentActions,
            ]) {
              if (!await _tableExists(table.actualTableName)) {
                await m.createTable(table);
              }
            }
            await _ensureAiAgentIndexes();
          }
          if (from < 137) {
            // v137：字幕书与远端（流式）音频的绑定表。纯新增、无回填；幂等守卫，
            // 迁移阶梯上按当前 Dart 定义已建过的库直接跳过。
            if (!await _tableExists('remote_audio_bindings')) {
              await m.createTable(remoteAudioBindings);
            }
          }
          if (from < 138) {
            // v138：remote_audio_bindings 加进度同步的两个基线时刻——
            // server_progress_at（上次对齐时服务器的 lastUpdate，服务器时钟）与
            // progress_synced_at（上次对齐的本机时刻，本机时钟）。续播判定从此不跨
            // 两台机器的时钟比较。存量行两列 NULL = 从没对齐过（判定退回冲突规则，
            // 与升级前行为一致）。幂等：v137 步按当前定义建表时已带这两列，跳过。
            if (await _tableExists('remote_audio_bindings')) {
              for (final GeneratedColumn<Object> column
                  in <GeneratedColumn<Object>>[
                remoteAudioBindings.serverProgressAt,
                remoteAudioBindings.progressSyncedAt,
              ]) {
                if (!await _columnExists('remote_audio_bindings', column.name)) {
                  await m.addColumn(remoteAudioBindings, column);
                }
              }
            }
          }
          if (from < 139) {
            // v139：music_play_events 加播放项快照（path / cue 起止 / 标题 / 艺人 / 专辑 /
            // 时长 / 封面）与播放来源（source_kind / source_id / source_title /
            // source_cover）。在线插件 / 服务器曲目不进 music_tracks，最近播放从此靠快照
            // 显示与重播；来源驱动「最近播放的歌单 / 专辑」。存量行全部 NULL（无快照、
            // 来源未知）。幂等：v130 步按当前定义建表时已带这些列，跳过。
            if (await _tableExists('music_play_events')) {
              for (final GeneratedColumn<Object> column
                  in <GeneratedColumn<Object>>[
                musicPlayEvents.path,
                musicPlayEvents.cueStartMs,
                musicPlayEvents.cueEndMs,
                musicPlayEvents.title,
                musicPlayEvents.artist,
                musicPlayEvents.album,
                musicPlayEvents.albumUid,
                musicPlayEvents.durationMs,
                musicPlayEvents.coverPath,
                musicPlayEvents.sourceKind,
                musicPlayEvents.sourceId,
                musicPlayEvents.sourceTitle,
                musicPlayEvents.sourceCover,
              ]) {
                if (!await _columnExists('music_play_events', column.name)) {
                  await m.addColumn(musicPlayEvents, column);
                }
              }
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
          await _ensureProfileUidIndex();
          await _ensureSrsIndexes();
          await _ensureMusicIndexes();
          await _ensureAiAgentIndexes();
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
          // 同理的最低版本门槛兜底（onUpgrade 里已先抛过一次）。
          if (before != null &&
              before > 0 &&
              before < kMinSupportedSchemaVersion) {
            throw UnsupportedLegacySchemaException(dbVersion: before);
          }

          // This one known same-version collision cannot reach onUpgrade.
          // Keep it after downgrade refusal and before any generated query;
          // do not rewrite user_version or replay unrelated migration steps.
          await _ensureDictionaryExpandedLanguagesColumn(createMigrator());

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

  /// 「统计日」重置整点（0..23，默认 0）——「今日」从几点开始；见
  /// [_FushiDbStatistics.statDayResetHour]。偏好键 [kStatDayResetHourPrefKey]。
  static int get statDayResetHour => _FushiDbStatistics.statDayResetHour;
  static set statDayResetHour(int hour) =>
      _FushiDbStatistics.statDayResetHour = hour;

  /// 日历日 → `yyyy-MM-dd`（不看重置整点）。
  static String statCalendarDayKeyOf(DateTime day) =>
      _FushiDbStatistics.statCalendarDayKeyOf(day);

  /// dateKey → 对应日历日（本地午夜 DateTime，只用于日历算术）。
  static DateTime statDateKeyToDay(String dateKey) =>
      _FushiDbStatistics.statDateKeyToDay(dateKey);

  /// 键算术：[dateKey] 往后 [days] 天（负数往前）。窗口 / streak / 热力图一律走
  /// 这里，不要把合成的午夜 DateTime 喂给 [statDateKeyOf]。
  static String statDateKeyPlusDays(String dateKey, int days) =>
      _FushiDbStatistics.statDateKeyPlusDays(dateKey, days);

  /// 到下一个统计日边界（下一次 `statDayResetHour:00`）的时长，恒 > 0。
  static Duration untilNextStatDayBoundary(DateTime now) =>
      _FushiDbStatistics.untilNextStatDayBoundary(now);

  /// v92 学习事实段的幂等键生成（转发 [_FushiDbStatistics.newStudySegmentUid]；
  /// mixin 的 static 不经类继承，这里给调用方一个稳定入口）。
  static String newStudySegmentUid() => _FushiDbStatistics.newStudySegmentUid();

  /// 段 provenance 用的设备身份偏好键（与 fushi 层 SyncRepository 同一把 key）。
  static const String studyDeviceIdPrefKey =
      _FushiDbStatistics.studyDeviceIdPrefKey;
}

int _epubBookUidCounter = 0;

/// 书的本机稳定 uid 生成（v81 / P3 Stage 1）：`book_<微秒时刻>_<进程内计数>`。
/// 与迁移回填的 `book_<rowid>_<秒时刻>` 同命名空间不同后缀形，互不相撞；
/// 进程内计数器兜同微秒批量导入。**机器局域**身份，不进 wire（那边仍是
/// bookKey）；跨设备无需一致。
String generateEpubBookUid() => 'book_${DateTime.now().microsecondsSinceEpoch}_'
    '${_epubBookUidCounter++}';
