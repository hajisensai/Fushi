/// 游戏刮削落库（`game.scrape.apply`）的撤销快照（AI 写操作必须可回滚，见
/// `fushi/CLAUDE.md` §13；库管家 spec `docs/specs/2026-11-18-ai-library-curator-design.md`
/// §6 第 4 条「认领必须可撤销」）。
///
/// 一次刮削落库动三处：
/// - `galgame_sources` 里该源的那一行（同 `(gameId, source)` 覆盖写）；
/// - `galgames` 行的 `primary_source` / `release_date`；
/// - 封面：`saveGameCoverBytes` 先删掉该游戏目录里的**全部**旧封面文件（任意扩展名）
///   再落新图，`cover_path` 指向新图。
///
/// 快照在执行前抓这三处的原值，封面文件另拷一份备份（备份的修改时间钉成抓快照的
/// 时刻，BUG-4844：复制会带上原图的修改时间，按修改时间清理的备份目录会把它当成
/// 老文件提前删掉）。撤销精确恢复：先前没有该源行就删掉、有就整行写回；两列写回原值；
/// 封面换过就把备份拷回原路径、删掉这次下载的新图。
///
/// 撤销前先比对「执行后」状态（[GalgameScrapeAfter]）：这次动过的东西之后又被改过
/// （再次刮削、手动换封面、换数据源）→ superseded，什么都不动。
///
/// 纯 Dart（不 import flutter / 插件 / `package:fushi`）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 撤销备份保留期（与书封面 / 视频认领撤销备份同一口径）。
const Duration kGalgameScrapeBackupRetention = Duration(days: 30);

/// 封面文件的指纹（`<字节数>:<修改时刻毫秒>`）；文件不在为 null。同步读一次 stat：
/// 撤销载荷在操作执行后同步拼出，封面换没换过只需要一个廉价的身份。
String? galgameCoverStamp(String? path) {
  if (path == null || path.isEmpty) return null;
  final FileStat stat = FileStat.statSync(path);
  if (stat.type != FileSystemEntityType.file) return null;
  return '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
}

/// 执行前快照。
class GalgameScrapeSnapshot {
  const GalgameScrapeSnapshot({
    required this.gameId,
    required this.source,
    required this.primarySource,
    required this.releaseDate,
    required this.coverPath,
    required this.coverStamp,
    required this.coverBackup,
    required this.sourceRow,
  });

  factory GalgameScrapeSnapshot.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('游戏刮削快照不是对象');
    final Object? gameId = raw['gameId'];
    final Object? source = raw['source'];
    if (gameId is! String || source is! String) {
      throw const FormatException('游戏刮削快照缺 gameId / source');
    }
    final Object? row = raw['sourceRow'];
    return GalgameScrapeSnapshot(
      gameId: gameId,
      source: source,
      primarySource: raw['primarySource'] as String?,
      releaseDate: raw['releaseDate'] as String?,
      coverPath: raw['coverPath'] as String?,
      coverStamp: raw['coverStamp'] as String?,
      coverBackup: raw['coverBackup'] as String?,
      sourceRow: row is Map ? GalgameScrapeSourceRow.fromJson(row) : null,
    );
  }

  final String gameId;

  /// 这次刮削的源 key（`bgm` / `vndb` / `dlsite`）。
  final String source;
  final String? primarySource;
  final String? releaseDate;
  final String? coverPath;

  /// 执行前封面文件的指纹（[galgameCoverStamp]）。
  final String? coverStamp;

  /// 执行前封面文件的备份路径；执行前没有封面文件为 null。
  final String? coverBackup;

  /// 执行前该源的快照行；null = 先前没有这个源。
  final GalgameScrapeSourceRow? sourceRow;

  Map<String, Object?> toJson() => <String, Object?>{
    'gameId': gameId,
    'source': source,
    'primarySource': primarySource,
    'releaseDate': releaseDate,
    'coverPath': coverPath,
    'coverStamp': coverStamp,
    'coverBackup': coverBackup,
    'sourceRow': sourceRow?.toJson(),
  };
}

/// `galgame_sources` 一行（整行写回用）。
class GalgameScrapeSourceRow {
  const GalgameScrapeSourceRow({
    required this.externalId,
    required this.dataJson,
    required this.score,
    required this.rank,
    required this.fetchedAt,
  });

  factory GalgameScrapeSourceRow.fromRow(GalgameSourceRow row) =>
      GalgameScrapeSourceRow(
        externalId: row.externalId,
        dataJson: row.dataJson,
        score: row.score,
        rank: row.rank,
        fetchedAt: row.fetchedAt,
      );

  factory GalgameScrapeSourceRow.fromJson(Map<Object?, Object?> raw) =>
      GalgameScrapeSourceRow(
        externalId: raw['externalId'] as String?,
        dataJson: '${raw['dataJson'] ?? ''}',
        score: (raw['score'] as num?)?.toDouble(),
        rank: (raw['rank'] as num?)?.toInt(),
        fetchedAt: (raw['fetchedAt'] as num?)?.toInt() ?? 0,
      );

  final String? externalId;
  final String dataJson;
  final double? score;
  final int? rank;
  final int fetchedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'externalId': externalId,
    'dataJson': dataJson,
    'score': score,
    'rank': rank,
    'fetchedAt': fetchedAt,
  };
}

/// 执行后状态（撤销前据此判 superseded）。
class GalgameScrapeAfter {
  const GalgameScrapeAfter({
    required this.primarySource,
    required this.releaseDate,
    required this.coverPath,
    required this.coverStamp,
    required this.externalId,
  });

  factory GalgameScrapeAfter.fromJson(Object? raw) {
    final Map<Object?, Object?> m = raw is Map ? raw : const {};
    return GalgameScrapeAfter(
      primarySource: m['primarySource'] as String?,
      releaseDate: m['releaseDate'] as String?,
      coverPath: m['coverPath'] as String?,
      coverStamp: m['coverStamp'] as String?,
      externalId: m['externalId'] as String?,
    );
  }

  final String? primarySource;
  final String? releaseDate;
  final String? coverPath;
  final String? coverStamp;

  /// 这次写进该源行的外部 id。
  final String? externalId;

  Map<String, Object?> toJson() => <String, Object?>{
    'primarySource': primarySource,
    'releaseDate': releaseDate,
    'coverPath': coverPath,
    'coverStamp': coverStamp,
    'externalId': externalId,
  };
}

/// 抓 [gameId] 在 [source] 上刮削落库前的快照；游戏不在抛 [StateError]。
Future<GalgameScrapeSnapshot> captureGalgameScrapeSnapshot(
  FushiDatabase db, {
  required String gameId,
  required String source,
  required Directory backupDirectory,
  DateTime Function()? clock,
}) async {
  final GalgameRow? game = await db.getGalgame(gameId);
  if (game == null) throw StateError('游戏库里没有 game:$gameId');
  GalgameScrapeSourceRow? sourceRow;
  for (final GalgameSourceRow row in await db.getGalgameSources(gameId)) {
    if (row.source == source) sourceRow = GalgameScrapeSourceRow.fromRow(row);
  }
  final String? coverPath = game.coverPath;
  final String? stamp = galgameCoverStamp(coverPath);
  String? backup;
  if (stamp != null) {
    await backupDirectory.create(recursive: true);
    await pruneGalgameScrapeBackups(backupDirectory);
    final DateTime now = (clock ?? DateTime.now)();
    backup = p.join(
      backupDirectory.path,
      '${now.microsecondsSinceEpoch}_$gameId${p.extension(coverPath!)}',
    );
    await File(coverPath).copy(backup);
    // BUG-4844：复制带上原图的修改时间；清理按修改时间判年龄，钉成现在。
    await File(backup).setLastModified(now);
  }
  return GalgameScrapeSnapshot(
    gameId: gameId,
    source: source,
    primarySource: game.primarySource,
    releaseDate: game.releaseDate,
    coverPath: coverPath,
    coverStamp: stamp,
    coverBackup: backup,
    sourceRow: sourceRow,
  );
}

/// 清掉 [directory] 里超过保留期的备份。
Future<void> pruneGalgameScrapeBackups(Directory directory) async {
  if (!directory.existsSync()) return;
  final DateTime cutoff = DateTime.now().subtract(
    kGalgameScrapeBackupRetention,
  );
  await for (final FileSystemEntity entity in directory.list()) {
    if (entity is! File) continue;
    if ((await entity.lastModified()).isBefore(cutoff)) {
      try {
        await entity.delete();
      } on FileSystemException {
        // 被占用：下次再清。
      }
    }
  }
}

/// 撤销结论。
enum GalgameScrapeRevertStatus { restored, superseded, failed }

class GalgameScrapeRevertResult {
  const GalgameScrapeRevertResult(this.status, [this.message]);

  final GalgameScrapeRevertStatus status;
  final String? message;
}

/// 把 [snapshot] 的游戏恢复到刮削落库前。判据全部在写之前查完：
/// - 游戏已不在 → superseded；
/// - 两列、封面路径或封面文件不等于 [after]、该源行不在或外部 id 不等于这次写的
///   → superseded（之后又被改过，保留现值）；
/// - 封面要恢复但备份丢了 → failed（不动库）。
///
/// 写库在一个事务里；封面先拷回（同路径时先把现图挪进暂存，任一步失败就放回），
/// 库写成功后才删这次下载的新图与备份。
Future<GalgameScrapeRevertResult> revertGalgameScrape(
  FushiDatabase db,
  GalgameScrapeSnapshot snapshot, {
  required GalgameScrapeAfter after,
}) async {
  final GalgameRow? game = await db.getGalgame(snapshot.gameId);
  if (game == null) {
    return const GalgameScrapeRevertResult(
      GalgameScrapeRevertStatus.superseded,
      '游戏已不在库里',
    );
  }
  GalgameSourceRow? current;
  for (final GalgameSourceRow row in await db.getGalgameSources(game.id)) {
    if (row.source == snapshot.source) current = row;
  }
  if (game.primarySource != after.primarySource ||
      game.releaseDate != after.releaseDate ||
      game.coverPath != after.coverPath ||
      galgameCoverStamp(game.coverPath) != after.coverStamp ||
      current == null ||
      current.externalId != after.externalId) {
    return const GalgameScrapeRevertResult(
      GalgameScrapeRevertStatus.superseded,
      '这次刮削写入的资料或封面之后又被改过，保留现值',
    );
  }
  final bool coverChanged =
      after.coverPath != snapshot.coverPath ||
      after.coverStamp != snapshot.coverStamp;
  final String? backup = snapshot.coverBackup;
  final String? beforePath = snapshot.coverPath;
  if (coverChanged &&
      snapshot.coverStamp != null &&
      (backup == null || !File(backup).existsSync())) {
    return const GalgameScrapeRevertResult(
      GalgameScrapeRevertStatus.failed,
      '封面撤销备份丢了，未改动',
    );
  }

  // ── 封面文件：先拷回，失败回滚 ─────────────────────────────────────────
  String? staged;
  bool restoredCopy = false;
  final String? afterPath = after.coverPath;
  if (coverChanged && snapshot.coverStamp != null) {
    try {
      if (afterPath == beforePath && File(beforePath!).existsSync()) {
        staged = '$beforePath.undo_${DateTime.now().microsecondsSinceEpoch}';
        await File(beforePath).rename(staged);
      }
      await File(beforePath!).parent.create(recursive: true);
      await File(backup!).copy(beforePath);
      restoredCopy = true;
    } on FileSystemException catch (e) {
      if (staged != null && File(staged).existsSync()) {
        await File(staged).rename(beforePath!);
      }
      return GalgameScrapeRevertResult(
        GalgameScrapeRevertStatus.failed,
        '封面拷回失败：${e.message}',
      );
    }
  }

  // ── 库：一个事务 ─────────────────────────────────────────────────────
  try {
    await db.transaction(() async {
      final GalgameScrapeSourceRow? row = snapshot.sourceRow;
      if (row == null) {
        await db.deleteGalgameSource(snapshot.gameId, snapshot.source);
      } else {
        await db.upsertGalgameSource(
          GalgameSourcesCompanion.insert(
            gameId: snapshot.gameId,
            source: snapshot.source,
            externalId: Value<String?>(row.externalId),
            dataJson: row.dataJson,
            score: Value<double?>(row.score),
            rank: Value<int?>(row.rank),
            fetchedAt: row.fetchedAt,
          ),
        );
      }
      await db.setGalgameScrapeResult(
        snapshot.gameId,
        primarySource: snapshot.primarySource,
        releaseDate: snapshot.releaseDate,
      );
      if (coverChanged) {
        await db.setGalgameCoverPath(snapshot.gameId, beforePath);
      }
    });
  } on Object catch (e) {
    // 库没写成：封面也放回执行后的样子。
    if (restoredCopy && beforePath != null) {
      if (staged != null) {
        await File(staged).copy(beforePath);
        await File(staged).delete();
      } else if (beforePath != afterPath && File(beforePath).existsSync()) {
        await File(beforePath).delete();
      }
    }
    return GalgameScrapeRevertResult(
      GalgameScrapeRevertStatus.failed,
      '写库失败：$e',
    );
  }

  // ── 收尾：删这次下载的新图、暂存与备份（失败不影响结论） ────────────────
  Future<void> quietDelete(String? path) async {
    if (path == null) return;
    try {
      final File f = File(path);
      if (f.existsSync()) await f.delete();
    } on FileSystemException {
      // 被占用：留给系统 / 下次清理。
    }
  }

  // 新图与原路径不同，或执行前根本没有封面文件（同路径时那张就是新下载的）。
  if (coverChanged &&
      afterPath != null &&
      (afterPath != beforePath || snapshot.coverStamp == null)) {
    await quietDelete(afterPath);
  }
  await quietDelete(staged);
  await quietDelete(backup);
  return const GalgameScrapeRevertResult(GalgameScrapeRevertStatus.restored);
}

/// 撤销没用上的备份（操作没改封面 / 撤销作废）：删掉。
Future<void> discardGalgameScrapeBackup(GalgameScrapeSnapshot snapshot) async {
  final String? backup = snapshot.coverBackup;
  if (backup == null) return;
  final File f = File(backup);
  if (f.existsSync()) await f.delete();
}
