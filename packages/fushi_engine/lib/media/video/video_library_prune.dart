/// 库扫描对账：回收「库里还在、磁盘上已不存在」的视频条目。
///
/// 背景：扫描器（服务端 `LibraryScanner`、app `SourceLibraryScanner`）都只做**单向**
/// 导入——把磁盘上有的文件补进库，从不反向清理文件已消失的行。用户手动删掉视频文件
/// 后，`video_books` 行连同挂在它上面的刮削资料（`video_scrape_meta` /
/// `video_metadata_*`）、规格缓存（`video_file_specs`，按路径为键、无 FK）与封面文件
/// 全部残留，客户端照旧列得出来。
///
/// 本模块提供对账原语：枚举库根下现存的视频文件，挑出「行还在、文件没了」的条目，
/// 走既有回收路径 [VideoBookRepository.deleteVideoBooksAndReclaimAssets] 删除
/// （级联清刮削资料 + 回收封面）。app 与服务端共用同一份判据。
///
/// 边界（有意）：
/// - 只在 [pruneMissingVideoRows] 的 `root` 路径范围内的行上动手；上传副本 / 下载
///   产物等库根之外的条目不受影响。
/// - 网络流（http/rtsp/`anime-source://`，见 `isNetworkOnlyVideoPath`）没有本地文件，
///   永不判失效。
/// - **不删任何用户文件**（`deleteLocalFiles: false`）；**不写跨设备删除墓碑**
///   （`DeleteScope.keepLocalOnly`）——这是「本机文件没了」的本地事实，不该把对端
///   的条目一起删掉。
/// - 破坏性操作带护栏：库根不存在、失效占比过高都拒绝执行（除非 `force`）；
///   护栏与书 / 漫画根共用（`library_prune_guard.dart`）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/source_library/library_prune_guard.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/strm_file.dart'
    show isNetworkOnlyVideoPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

/// 枚举 [root] 下现存的视频文件路径（[normalizeVideoPath] 归一）。纯文件系统读。
Future<Set<String>> enumerateLocalVideoPaths(
  Directory root, {
  bool recursive = true,
}) async {
  final Set<String> out = <String>{};
  await for (final FileSystemEntity e in root.list(
    recursive: recursive,
    followLinks: false,
  )) {
    if (e is! File) continue;
    // 与服务端视频根扫描收录同一张表（视频 + 纯音频）：少一个格式，该格式的
    // 在库行就会被当成「磁盘上已不存在」修剪掉。
    if (!kVideoLibraryMediaExtensions.contains(
      p.extension(e.path).toLowerCase(),
    )) {
      continue;
    }
    out.add(normalizeVideoPath(e.path));
  }
  return out;
}

/// 纯函数：挑出落在 [rootPath] 内的候选行（归一后前缀匹配）。
///
/// 服务端的库行不记 `source_id`，所以「属于哪个库根」只能按物理路径判定。
List<VideoBookRow> videoRowsWithinRoot(
  Iterable<VideoBookRow> rows,
  String rootPath,
) {
  final String root = normalizeVideoPath(rootPath);
  if (root.isEmpty) return const <VideoBookRow>[];
  return <VideoBookRow>[
    for (final VideoBookRow row in rows)
      if (row.videoPath.isNotEmpty &&
          p.isWithin(root, normalizeVideoPath(row.videoPath)))
        row,
  ];
}

/// 纯函数：从候选行里挑出「文件已不存在」的行。
///
/// [candidates] 应只包含目标库根范围内的行；[foundPaths] 是本次枚举到的归一路径
/// 集合；[exists] 可注入以便测试（默认 `File(path).existsSync()`）。
///
/// 网络流（[isNetworkOnlyVideoPath]）永不判失效——它们本来就没有本地文件。
/// 即便 [foundPaths] 未命中，也要 [exists] 二次确认：枚举可能因权限或竞态漏项，
/// 真不存在才删。
///
/// 多集合集行（`playlistJson` 非空）不在本判据内：它的 `videoPath` 只是其中一集，
/// 一集没了不等于整行失效；按成员对账是另一件事，这里宁可不动。
List<VideoBookRow> selectStaleVideoRows({
  required Iterable<VideoBookRow> candidates,
  required Set<String> foundPaths,
  bool Function(String path)? exists,
}) {
  final bool Function(String path) fileExists =
      exists ?? (String path) => File(path).existsSync();
  final List<VideoBookRow> stale = <VideoBookRow>[];
  for (final VideoBookRow row in candidates) {
    final String primary = row.videoPath;
    if (primary.isEmpty) continue;
    if (isNetworkOnlyVideoPath(primary)) continue;
    if ((row.playlistJson ?? '').trim().isNotEmpty) continue;
    if (foundPaths.contains(normalizeVideoPath(primary))) continue;
    if (fileExists(primary)) continue;
    stale.add(row);
  }
  return stale;
}

/// 对 [root] 下的视频库做一次对账：挑出文件已消失的行并回收。
///
/// [foundPaths] 为空时自行枚举（调用方已经枚举过就传进来，避免重复遍历磁盘）。
/// [baselineBookUids] 是**本轮扫描导入前**库里已有的行：扫描器先导入、后对账，
/// 给了基线就只在这些行上判失效与算护栏比例——否则「整库改名 / 搬家」时本轮新加
/// 的行会把分母撑大一倍，让本该被拦下的整批删除刚好卡在阈值上放行。
/// [dryRun] 只算不删（返回的 `missing` 即计划删除数，`deleted` 恒 0）。
///
/// 护栏（[force] 全部越过，只留「文件确实不存在」这条判据；给「移除并清理」这类
/// 显式用户意图用）：
/// - 库根不存在 → 拒绝；
/// - 库根在但一个视频文件都枚举不到 → 拒绝（空挂载点）；
/// - 失效行所在子树疑似脱挂（[isPathInDetachedSubtree]）→ 该行不判失效；
/// - 失效占比越过 [threshold] → 拒绝。
Future<LibraryPruneReport> pruneMissingVideoRows({
  required VideoBookRepository repository,
  required Directory root,
  Set<String>? foundPaths,
  Set<String>? baselineBookUids,
  LibraryPruneThreshold threshold = const LibraryPruneThreshold(),
  bool force = false,
  bool dryRun = false,
  bool Function(String path)? exists,
}) async {
  final List<VideoBookRow> candidates = <VideoBookRow>[
    for (final VideoBookRow row in videoRowsWithinRoot(
      await repository.listAll(),
      root.path,
    ))
      if (baselineBookUids == null || baselineBookUids.contains(row.bookUid))
        row,
  ];
  if (candidates.isEmpty) {
    return const LibraryPruneReport(considered: 0, missing: 0, deleted: 0);
  }
  final bool rootExists = await root.exists();
  final Set<String> found =
      foundPaths ??
      (rootExists ? await enumerateLocalVideoPaths(root) : <String>{});
  // 库根不存在 / 空挂载点：绝不 prune。NFS 未挂载 / USB 拔掉会把整库删光，
  // 这是本模块最大的事故面（护栏与书 / 漫画根共用）。
  final String? rootSkip = force
      ? null
      : libraryRootSkipReason(
          rootPath: root.path,
          rootExists: rootExists,
          foundAny: found.isNotEmpty,
          mediaNoun: 'video files',
        );
  if (rootSkip != null) {
    return LibraryPruneReport(
      considered: candidates.length,
      missing: 0,
      deleted: 0,
      skipped: true,
      skipReason: rootSkip,
    );
  }
  final List<VideoBookRow> missingRows = selectStaleVideoRows(
    candidates: candidates,
    foundPaths: found,
    exists: exists,
  );
  final List<VideoBookRow> stale = <VideoBookRow>[
    for (final VideoBookRow row in missingRows)
      if (force || !isPathInDetachedSubtree(row.videoPath, root.path)) row,
  ];
  final int unreachable = missingRows.length - stale.length;
  if (stale.isEmpty) {
    return LibraryPruneReport(
      considered: candidates.length,
      missing: 0,
      deleted: 0,
      unreachable: unreachable,
    );
  }
  final String? thresholdSkip = force
      ? null
      : threshold.skipReason(
          stale: stale.length,
          considered: candidates.length,
        );
  if (thresholdSkip != null) {
    return LibraryPruneReport(
      considered: candidates.length,
      missing: stale.length,
      deleted: 0,
      unreachable: unreachable,
      skipped: true,
      skipReason: thresholdSkip,
    );
  }
  if (dryRun) {
    return LibraryPruneReport(
      considered: candidates.length,
      missing: stale.length,
      deleted: 0,
      unreachable: unreachable,
    );
  }
  // 自己先取刮削租约：拿不到（刮削资料清理在跑）就如实跳过。不靠捕获删除抛出的
  // `StateError` 分辨——那会把数据库自身的 StateError 也当成「租约被占」吞掉。
  // 普通 operation 可以叠加，删除内部再取一次不会自锁。
  final VideoScrapeOperationLease? lease =
      VideoScrapeOperationGate.tryEnterOperation();
  if (lease == null) {
    return LibraryPruneReport(
      considered: candidates.length,
      missing: stale.length,
      deleted: 0,
      unreachable: unreachable,
      skipped: true,
      skipReason: 'video scrape maintenance in progress',
    );
  }
  final List<String> errors = <String>[];
  int deleted = 0;
  try {
    deleted = await repository.deleteVideoBooksAndReclaimAssets(
      stale.map((VideoBookRow r) => r.bookUid),
      scope: DeleteScope.keepLocalOnly,
      compactDatabase: false,
      deleteLocalFiles: false,
    );
  } on VideoBooksDeleteException catch (e) {
    // 部分成功：已删的照实计数，失败的行留在库里、下轮再判。
    deleted = e.deletedCount;
    errors.add('$e');
  } catch (e) {
    errors.add('$e');
  } finally {
    lease.release();
  }
  return LibraryPruneReport(
    considered: candidates.length,
    missing: stale.length,
    deleted: deleted,
    unreachable: unreachable,
    errors: errors,
  );
}
