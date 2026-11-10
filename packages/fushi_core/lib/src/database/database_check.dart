import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../utils/fushi_debug_print.dart';
import 'database.dart';
import 'sql_functions.dart';
import 'sqlite_busy_timeout.dart';

/// 「检查数据库」（反馈 s2fdTTmLyh，类 Anki「Check Database」）的阶段，按执行顺序。
///
/// 全部 SQL 都经主库自己的 drift 连接发出——生产上那是
/// `NativeDatabase.createInBackground` 的后台 isolate：integrity_check / VACUUM /
/// 修复都不在 UI isolate 跑，且与 app 其余读写在同一条连接上**排队**而不是抢锁
/// （另开连接跑几分钟的 VACUUM 会让 app 的写入撞 5 s busy 超时直接报错）。
enum DatabaseCheckPhase {
  /// `PRAGMA integrity_check`：只读，先看清现状。
  integrity,

  /// `VACUUM INTO` 整库一致性备份；备份失败就不做任何改动。
  backup,

  /// 修复：结构问题先 `REINDEX`；再把已知坏数据（Latin-1 乱码统计行）并回原桶。
  /// 统计行修复在一个事务里，失败整体回滚。
  repair,

  /// `VACUUM` + `wal_checkpoint(TRUNCATE)`：把删掉的空间还给磁盘。
  compact,

  /// 再跑一遍 `integrity_check`；本来完好、做完反而坏了 → 从备份整库回滚。
  verify,
}

/// 「检查数据库」的结果。不抛异常：每个阶段的失败都落进 [failure] /
/// [failedPhase] 原样带给用户（并 `fushiDebugPrint`），不吞。
class DatabaseCheckReport {
  const DatabaseCheckReport({
    required this.problemsFound,
    required this.problemsRemaining,
    required this.sizeBeforeBytes,
    required this.sizeAfterBytes,
    this.reindexed = false,
    this.repairedReadingStatRows = 0,
    this.repairedLookupCounterRows = 0,
    this.backupPath,
    this.backupBytes,
    this.rolledBack = false,
    this.failedPhase,
    this.failure,
  });

  /// 修复前 integrity_check 报的问题（空 = ok）。
  final List<String> problemsFound;

  /// 做完之后仍在的问题（空 = ok）。
  final List<String> problemsRemaining;

  /// 是否因结构问题跑过 REINDEX。
  final bool reindexed;

  /// 并回原桶、删掉的乱码 `reading_statistics` 行数。
  final int repairedReadingStatRows;

  /// 并回原桶、删掉的乱码 `lookup_mining_counters` 行数。
  final int repairedLookupCounterRows;

  /// 主库（含 `-wal`）检查前 / 后的字节数。
  final int sizeBeforeBytes;
  final int sizeAfterBytes;

  /// 本次备份的绝对路径；null = 没有留下备份（备份失败，或什么都没改所以删了）。
  final String? backupPath;
  final int? backupBytes;

  /// 是否已从备份把整库回滚到检查前。
  final bool rolledBack;

  /// 出错的阶段与原因；null = 全部阶段都跑完。
  final DatabaseCheckPhase? failedPhase;
  final String? failure;

  int get repairedRows => repairedReadingStatRows + repairedLookupCounterRows;

  /// 全部阶段跑完且最终 integrity_check 为 ok。
  bool get healthy => failure == null && problemsRemaining.isEmpty;

  /// 控制通道 / 日志用的结构化形态。
  Map<String, Object?> toJson() => <String, Object?>{
    'healthy': healthy,
    'problemsFound': problemsFound,
    'problemsRemaining': problemsRemaining,
    'reindexed': reindexed,
    'repairedReadingStatRows': repairedReadingStatRows,
    'repairedLookupCounterRows': repairedLookupCounterRows,
    'sizeBeforeBytes': sizeBeforeBytes,
    'sizeAfterBytes': sizeAfterBytes,
    'backupPath': backupPath,
    'backupBytes': backupBytes,
    'rolledBack': rolledBack,
    'failedPhase': failedPhase?.name,
    'failure': failure,
  };
}

/// integrity_check 最多收集的问题条数（SQLite 默认 100；报告只需要看得出病情）。
const int kDatabaseCheckMaxProblems = 100;

/// 从备份文件把 [dbPath] 整库换回去（[runDatabaseCheck] 回滚用）。可注入以便测试。
typedef DatabaseRestoreFromBackup =
    Future<void> Function({required String backupPath, required String dbPath});

/// 跑一遍「检查数据库」：完整性检查 → 备份 → 修复 → 压缩 → 复检（见
/// [DatabaseCheckPhase]）。[onPhase] 在每个阶段开始时回调，UI 据此显示进度。
///
/// 安全纪律：
/// - **先备份再动手**：`VACUUM INTO` 出一份事务一致的整库副本到 [backupPath]
///   （名字用 [databaseCheckBackupFileName]，存储页能列出 / 删除）；备份失败直接
///   结束，库一个字节都不动。
/// - **失败可回滚**：统计行修复在单个事务里，任何一步抛错整体回滚；VACUUM 本身
///   是原子的。复检发现做完后库反而不完好时，用 SQLite backup API 把备份整库写回。
/// - 什么都没改（修复阶段之前就失败）时删掉这份备份，不白占一份整库大小的空间。
/// - 本次备份成功后删掉更早的「检查数据库」备份，只留最近一份。
Future<DatabaseCheckReport> runDatabaseCheck(
  final FushiDatabase db, {
  required final String dbPath,
  required final String backupPath,
  final void Function(DatabaseCheckPhase phase)? onPhase,
  final DatabaseRestoreFromBackup restoreFromBackup =
      restoreDatabaseFromBackup,
}) async {
  final int sizeBefore = await _databaseBytes(dbPath);
  DatabaseCheckPhase phase = DatabaseCheckPhase.integrity;
  List<String> problemsFound = const <String>[];
  List<String> problemsRemaining = const <String>[];
  bool reindexed = false;
  int readingRows = 0;
  int lookupRows = 0;
  bool backupTaken = false;
  bool changed = false;
  bool rolledBack = false;

  Future<DatabaseCheckReport> finish({
    final Object? error,
    final StackTrace? stack,
  }) async {
    if (error != null) {
      fushiDebugPrint(
        '[db-check] phase ${phase.name} failed: $error\n${stack ?? ''}',
      );
    }
    String? keptBackup = backupTaken ? backupPath : null;
    if (keptBackup != null && !changed) {
      // 修复前就结束（只读检查 / 备份阶段出错）：库没动，备份没用处。
      await _deleteQuietly(keptBackup);
      keptBackup = null;
    } else if (error != null && !backupTaken) {
      // 备份阶段半途失败可能留下半截文件。
      await _deleteQuietly(backupPath);
    }
    return DatabaseCheckReport(
      problemsFound: problemsFound,
      problemsRemaining: problemsRemaining,
      reindexed: reindexed,
      repairedReadingStatRows: readingRows,
      repairedLookupCounterRows: lookupRows,
      sizeBeforeBytes: sizeBefore,
      sizeAfterBytes: await _databaseBytes(dbPath),
      backupPath: keptBackup,
      backupBytes: keptBackup == null ? null : await _fileBytes(keptBackup),
      rolledBack: rolledBack,
      failedPhase: error == null ? null : phase,
      failure: error?.toString(),
    );
  }

  try {
    // ── 1. 完整性检查（只读）。
    onPhase?.call(phase);
    problemsFound = await databaseIntegrityProblems(db);
    problemsRemaining = problemsFound;

    // ── 2. 备份。
    phase = DatabaseCheckPhase.backup;
    onPhase?.call(phase);
    await _deleteQuietly(backupPath);
    await db.customStatement('VACUUM INTO ?', <Object?>[backupPath]);
    backupTaken = true;
    await _pruneOlderCheckBackups(backupPath);

    // ── 3. 修复。
    phase = DatabaseCheckPhase.repair;
    onPhase?.call(phase);
    if (problemsFound.isNotEmpty) {
      // integrity_check 最常见的问题是索引与表不一致，REINDEX 能就地重建；
      // 表本身的 b-tree 坏了它修不了，下面复查会如实报出来。
      await db.customStatement('REINDEX');
      reindexed = true;
      changed = true;
      problemsRemaining = await databaseIntegrityProblems(db);
      if (problemsRemaining.isNotEmpty) {
        // 就地修不好：不在坏库上继续改写 / VACUUM，留着备份交给用户。
        return await finish();
      }
    }
    final (int, int) repaired = await repairLatin1MojibakeStatistics(db);
    readingRows = repaired.$1;
    lookupRows = repaired.$2;
    if (readingRows + lookupRows > 0) changed = true;

    // ── 4. 压缩。VACUUM 失败不影响已提交的修复，记下原因后照样复检。
    phase = DatabaseCheckPhase.compact;
    onPhase?.call(phase);
    Object? compactError;
    StackTrace? compactStack;
    try {
      await db.customStatement('VACUUM');
      changed = true;
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e, st) {
      compactError = e;
      compactStack = st;
    }

    // ── 5. 复检。走到这里时库是完好的（原本就 ok，或 REINDEX 已修好——修不好的
    //    在上面就返回了），做完反而坏了 → 整库回滚到检查前。
    phase = DatabaseCheckPhase.verify;
    onPhase?.call(phase);
    problemsRemaining = await databaseIntegrityProblems(db);
    if (problemsRemaining.isNotEmpty) {
      await restoreFromBackup(backupPath: backupPath, dbPath: dbPath);
      rolledBack = true;
      db.markTablesUpdated(db.allTables);
      problemsRemaining = await databaseIntegrityProblems(db);
      return await finish(
        error: StateError(
          'integrity_check failed after maintenance; restored the backup',
        ),
      );
    }
    if (compactError != null) {
      phase = DatabaseCheckPhase.compact;
      return await finish(error: compactError, stack: compactStack);
    }
    return await finish();
  } catch (e, st) {
    return finish(error: e, stack: st);
  }
}

/// `PRAGMA integrity_check` 的问题清单；空 = ok。
Future<List<String>> databaseIntegrityProblems(final FushiDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect('PRAGMA integrity_check($kDatabaseCheckMaxProblems)')
      .get();
  final List<String> messages = <String>[
    for (final QueryRow row in rows) '${row.data.values.first}',
  ];
  if (messages.length == 1 && messages.single == 'ok') return const <String>[];
  return messages;
}

/// 已知坏数据修复：BUG-4243（反馈 hbIHtWi2Q7）的 Latin-1 乱码统计行。
///
/// 乱码副本是同一个 (书名, 日期) 桶在每轮往返中多出来的一份，数值是原桶的拷贝，
/// 所以按同步的 MAX-union 语义把它们**逐字段取 MAX 并回剥层后的原桶**，再删掉乱码
/// 行（直接相加会把同一段阅读重复计好几倍——用户实测 561 s vs 57 s）。
/// 统计墓碑（`statistics_tombstones`）刻意不动：乱码书名的墓碑是用户删掉那条乱码
/// 统计时立的，剥层会把它变成真书名的墓碑、误删真统计。
///
/// 单事务：任何一条语句失败整体回滚。返回 (阅读统计删掉的行数, 查词计数删掉的行数)。
/// 剥层在 SQL 自定义函数里做（[registerFushiSqlFunctions]），几十 MB 的乱码书名不
/// 出 drift 后台 isolate。
Future<(int, int)> repairLatin1MojibakeStatistics(final FushiDatabase db) {
  return db.transaction(() async {
    await db.customStatement('''
INSERT INTO reading_statistics
  (title, date_key, characters_read, reading_time_ms, pages_read,
   last_statistic_modified)
SELECT $kSqlUnwrapMojibake(title) AS clean_title, date_key,
       MAX(characters_read), MAX(reading_time_ms), MAX(pages_read),
       MAX(last_statistic_modified)
FROM reading_statistics
WHERE $kSqlHasMojibake(title)
GROUP BY clean_title, date_key
ON CONFLICT(title, date_key) DO UPDATE SET
  characters_read = MAX(characters_read, excluded.characters_read),
  reading_time_ms = MAX(reading_time_ms, excluded.reading_time_ms),
  pages_read = MAX(pages_read, excluded.pages_read),
  last_statistic_modified =
    MAX(last_statistic_modified, excluded.last_statistic_modified)
''');
    final int reading = await db.customUpdate(
      'DELETE FROM reading_statistics WHERE $kSqlHasMojibake(title)',
      updates: <ResultSetImplementation>{db.readingStatistics},
      updateKind: UpdateKind.delete,
    );
    await db.customStatement('''
INSERT INTO lookup_mining_counters
  (book_key, title, source_type, date_key, lookup_count, mine_count)
SELECT $kSqlUnwrapMojibake(book_key) AS clean_key,
       $kSqlUnwrapMojibake(title) AS clean_title, source_type, date_key,
       MAX(lookup_count), MAX(mine_count)
FROM lookup_mining_counters
WHERE $kSqlHasMojibake(title) OR $kSqlHasMojibake(book_key)
GROUP BY clean_key, clean_title, source_type, date_key
ON CONFLICT(title, source_type, date_key, book_key) DO UPDATE SET
  lookup_count = MAX(lookup_count, excluded.lookup_count),
  mine_count = MAX(mine_count, excluded.mine_count)
''');
    final int lookup = await db.customUpdate(
      'DELETE FROM lookup_mining_counters '
      'WHERE $kSqlHasMojibake(title) OR $kSqlHasMojibake(book_key)',
      updates: <ResultSetImplementation>{db.lookupMiningCounters},
      updateKind: UpdateKind.delete,
    );
    return (reading, lookup);
  });
}

/// 用 SQLite backup API 把 [backupPath] 整库写回 [dbPath]（在线回滚：主库的 drift
/// 连接不用关，SQLite 自己让其它连接看到新内容）。跑在一次性 isolate 里，连接自带
/// 墙钟 busy 超时；写回本身是 backup API 的单步原子操作。
Future<void> restoreDatabaseFromBackup({
  required final String backupPath,
  required final String dbPath,
}) {
  return Isolate.run(() async {
    final sqlite3.Database source = sqlite3.sqlite3.open(
      backupPath,
      mode: sqlite3.OpenMode.readOnly,
    );
    try {
      final sqlite3.Database target = sqlite3.sqlite3.open(dbPath);
      try {
        installWallClockBusyTimeout(target);
        await source.backup(target, nPage: -1).drain<void>();
      } finally {
        target.close();
      }
    } finally {
      source.close();
    }
  });
}

/// 本次备份成功后，删掉同目录里更早的「检查数据库」备份（只留最近一份）。
Future<void> _pruneOlderCheckBackups(final String keepPath) async {
  final Directory dir = Directory(p.dirname(keepPath));
  final String keepName = p.basename(keepPath);
  await for (final FileSystemEntity e in dir.list(followLinks: false)) {
    final String name = p.basename(e.path);
    if (e is File &&
        name != keepName &&
        isDatabaseCheckBackupFileName(name)) {
      await _deleteQuietly(e.path);
    }
  }
}

/// 删备份副本；删不掉只记日志——它不是活数据，存储页「数据库备份快照」还能再删。
Future<void> _deleteQuietly(final String path) async {
  final File f = File(path);
  try {
    if (await f.exists()) await f.delete();
  } on FileSystemException catch (e) {
    fushiDebugPrint('[db-check] could not delete "$path": $e');
  }
}

Future<int> _databaseBytes(final String dbPath) async =>
    await _fileBytes(dbPath) + await _fileBytes('$dbPath-wal');

Future<int> _fileBytes(final String path) async {
  final File f = File(path);
  return await f.exists() ? f.length() : 0;
}
