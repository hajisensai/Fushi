/// 存量迁移：BUG-4245 修复前逐个入库的蓝光流文件行（`BDMV/STREAM/00002.m2ts`）
/// 换成正规原盘合集（BUG-5285）。
///
/// 那批行每条只是盘里的一个片段，标题是片段号「00002」，资料源与 AI 都认不出（BUG-5280
/// 已让它们不再进刮削计划），但卡片仍堆在视频库里。盘结构在磁盘上完好时，走与扫描器 /
/// 下载流水线同一个 [DiscLibraryImporter] 把盘根导入成盘合集，再：
/// - 流文件行所在的**别的**合集（用户自建清单等）换成这张盘的标题行，用户的归类意图
///   不丢（成员记成用户放进来的，AI 整理不会移走）；
/// - 回收流文件行（[VideoBookRepository.deleteVideoBooksAndReclaimAssets]，不删
///   用户文件、不写跨设备删除墓碑）。
///
/// 片段行上的断点不折到标题上：片段只是标题的一段，片段内时间与标题时间轴对不上，
/// 硬折会把断点放到错的位置。
///
/// 按数据幂等：库里没有流文件行就什么都不做；盘读不出（残盘、还在拷、文件夹没了）的
/// 行原样留着，下次再试。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show isDiscStreamFilePath;
import 'package:fushi_engine/media/video/disc/disc_library_import.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart' show DeleteScope;

/// 一次迁移的结果。
class LegacyDiscStreamMigrationReport {
  const LegacyDiscStreamMigrationReport({
    this.candidates = 0,
    this.discs = 0,
    this.reclaimed = 0,
    this.membershipsCarried = 0,
    this.unreadableRoots = const <String>[],
  });

  /// 库里的流文件行数。
  final int candidates;

  /// 入了库（新建或对齐）的盘数。
  final int discs;

  /// 回收掉的流文件行数。
  final int reclaimed;

  /// 换进用户合集的标题成员数。
  final int membershipsCarried;

  /// 读不出的盘根（行原样留着）。
  final List<String> unreadableRoots;
}

/// 蓝光流文件行的盘根（含 `BDMV` 的那一层）：`.m2ts` 在 `BDMV/STREAM/`，`.ssif` 在
/// `BDMV/STREAM/SSIF/`。DVD 的 `VIDEO_TS/*.VOB` 不在这里处理（返回 null）。
String? blurayDiscRootForStreamFilePath(String path) {
  if (!isDiscStreamFilePath(path)) return null;
  final String extension = p.extension(path).toLowerCase();
  final List<String> parts = p.split(p.normalize(path));
  final int up = switch (extension) {
    '.m2ts' => 3,
    '.ssif' => 4,
    _ => 0,
  };
  // 盘根要拿来在本机读盘：只接受宿主平台能切开的路径。另一平台的路径（Linux 上的
  // `D:\…`）[isDiscStreamFilePath] 认得，但本机 `package:path` 切不开、也读不到。
  if (up == 0 || parts.length <= up) return null;
  return p.joinAll(parts.sublist(0, parts.length - up));
}

/// 把库里的蓝光流文件行换成盘合集。见库注释。
Future<LegacyDiscStreamMigrationReport> migrateLegacyDiscStreamRows(
  FushiDatabase db,
) async {
  final VideoBookRepository repo = VideoBookRepository(db);
  // 盘根（规范化）→ 原始盘根 / 该盘上的流文件行。
  final Map<String, String> rootPaths = <String, String>{};
  final Map<String, List<VideoBookRow>> rowsByRoot =
      <String, List<VideoBookRow>>{};
  for (final VideoBookRow row in await repo.listAll()) {
    final String? root = blurayDiscRootForStreamFilePath(row.videoPath);
    if (root == null) continue;
    final String key = normalizeVideoPath(root);
    rootPaths.putIfAbsent(key, () => root);
    rowsByRoot.putIfAbsent(key, () => <VideoBookRow>[]).add(row);
  }
  if (rowsByRoot.isEmpty) return const LegacyDiscStreamMigrationReport();
  final int candidates = rowsByRoot.values.fold<int>(
    0,
    (int sum, List<VideoBookRow> rows) => sum + rows.length,
  );

  // 同一来源的盘一起导入：同一发布的几张盘要并进一个合集（按盘序排）。流文件行
  // 来源不一致的盘按无来源处理（与下载流水线不带来源时一致）。
  final Map<int?, List<String>> rootsBySource = <int?, List<String>>{};
  for (final MapEntry<String, List<VideoBookRow>> entry in rowsByRoot.entries) {
    final Set<int?> sources = <int?>{
      for (final VideoBookRow row in entry.value) row.sourceId,
    };
    final int? sourceId = sources.length == 1 ? sources.single : null;
    rootsBySource
        .putIfAbsent(sourceId, () => <String>[])
        .add(rootPaths[entry.key]!);
  }

  final DiscLibraryImporter importer = DiscLibraryImporter(db);
  final List<DiscLibraryImportedDisc> imported = <DiscLibraryImportedDisc>[];
  final List<String> unreadable = <String>[];
  for (final MapEntry<int?, List<String>> entry in rootsBySource.entries) {
    final DiscLibraryImportReport report = await importer.importBlurayDiscs(
      entry.value..sort(),
      sourceId: entry.key,
      // 这些盘是用户当初明确导入的，删过同名合集也重建（与下载入库同口径）。
      restoreDissolvedGroups: true,
    );
    imported.addAll(report.discs);
    unreadable.addAll(report.unreadable);
  }
  if (imported.isEmpty) {
    return LegacyDiscStreamMigrationReport(
      candidates: candidates,
      unreadableRoots: List<String>.unmodifiable(unreadable),
    );
  }

  final Map<String, String> uidByPath = <String, String>{
    for (final VideoBookRow row in await repo.listAll())
      normalizeVideoPath(row.videoPath): row.bookUid,
  };
  final Map<String, Set<int>> collectionsByEntry = <String, Set<int>>{};
  for (final MediaCollectionItemRow item in await db.getAllCollectionItems()) {
    if (item.mediaType != MediaKind.video.dbValue) continue;
    collectionsByEntry
        .putIfAbsent(item.entryKey, () => <int>{})
        .add(item.collectionId);
  }

  int carried = 0;
  final List<String> stale = <String>[];
  for (final DiscLibraryImportedDisc disc in imported) {
    final List<VideoBookRow> rows =
        rowsByRoot[normalizeVideoPath(disc.rootPath)] ?? const <VideoBookRow>[];
    if (rows.isEmpty) continue;
    final List<String> titleUids = <String>[
      for (final String path in disc.titlePaths)
        if (uidByPath[normalizeVideoPath(path)] case final String uid) uid,
    ];
    // 盘没切出任何标题行（合集被挡下等）：流文件行是这张盘唯一的入口，不回收。
    if (titleUids.isEmpty) continue;
    final Set<int> targets = <int>{
      for (final VideoBookRow row in rows) ...?collectionsByEntry[row.bookUid],
    }..remove(disc.collectionId);
    for (final int collectionId in targets) {
      final Set<String> existing = <String>{
        for (final MediaCollectionItemRow item in await db.getCollectionItems(
          collectionId,
        ))
          if (item.mediaType == MediaKind.video.dbValue) item.entryKey,
      };
      for (final String uid in titleUids) {
        if (existing.contains(uid)) continue;
        await db.addToCollectionRaw(
          collectionId,
          MediaKind.video.dbValue,
          uid,
          // 迁移是自动路径，不接手合集所有权；但成员是用户当初放进来的，钉住。
          userIntent: false,
          pinnedByUser: true,
        );
        carried++;
      }
    }
    stale.addAll(rows.map((VideoBookRow row) => row.bookUid));
  }

  int reclaimed = 0;
  if (stale.isNotEmpty) {
    try {
      reclaimed = await repo.deleteVideoBooksAndReclaimAssets(
        stale,
        scope: DeleteScope.keepLocalOnly,
        compactDatabase: false,
        deleteLocalFiles: false,
      );
    } on StateError {
      // 刮削资料清理在跑：这些行留在库里，下次再回收（合集成员已换好，重跑幂等）。
    } on VideoBooksDeleteException catch (e) {
      reclaimed = e.deletedCount;
    }
  }
  return LegacyDiscStreamMigrationReport(
    candidates: candidates,
    discs: imported.length,
    reclaimed: reclaimed,
    membershipsCarried: carried,
    unreadableRoots: List<String>.unmodifiable(unreadable),
  );
}
