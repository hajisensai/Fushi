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
/// - 破坏性操作带护栏：库根不存在、失效占比过高都拒绝执行（除非 `force`）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/strm_file.dart'
    show isNetworkOnlyVideoPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

/// 单次对账的护栏阈值：失效占比超过 [ratio] **且**失效数超过 [absoluteFloor] 时
/// 拒绝执行（除非调用方显式 `force`）。
///
/// 两个条件同时成立才拦，是为了让**小库**能被完整清理（用户删光一个小库是正常意图），
/// 而**大库**在「挂载点空了 / NFS 掉了」这类事故下不会被整批删光。[absoluteFloor]
/// 是「多少条以下不设比例门」的绝对下限。
class VideoPruneThreshold {
  const VideoPruneThreshold({this.ratio = 0.5, this.absoluteFloor = 10});

  final double ratio;
  final int absoluteFloor;

  /// [stale] / [considered] 是否突破护栏。
  bool exceeded({required int stale, required int considered}) =>
      stale > absoluteFloor && considered > 0 && stale / considered > ratio;
}

/// 一次对账的结果。
class VideoPruneReport {
  const VideoPruneReport({
    required this.considered,
    required this.missing,
    required this.deleted,
    this.unreachable = 0,
    this.skipped = false,
    this.skipReason,
    this.errors = const <String>[],
  });

  /// 候选行数（落在 root 内；给了基线时只算本轮扫描前就在库里的行）。
  final int considered;

  /// 其中文件确已不存在的行数。
  final int missing;

  /// 文件找不到、但所在子树疑似脱挂（最近的现存上级目录是空的或列不出来）
  /// 而**没有**判失效的行数。见 [pruneMissingVideoRows]。
  final int unreachable;

  /// 实际删除的行数。
  final int deleted;

  /// 是否被护栏 / 刮削租约拦下（未执行删除）。
  final bool skipped;
  final String? skipReason;
  final List<String> errors;

  @override
  String toString() => skipped
      ? 'prune skipped ($skipReason; considered $considered, missing $missing)'
      : 'pruned $deleted/$missing (considered $considered'
            '${unreachable > 0 ? ', unreachable $unreachable' : ''})';
}

/// [filePath] 所在子树是否疑似「挂载点掉了」：从文件的上级目录往上找到第一个现存
/// 目录（不越过 [rootPath]），它若是**空的**或**列不出来**（权限 / IO 错误），就当
/// 不可达而不是「文件被删」。
///
/// 用户删一整季通常连目录一起删，最近的现存上级是非空的库根或父目录 → 照常判失效；
/// 子挂载点（`/media/disk2`）掉线后留下的是一个空目录 → 这里拦住，不把那块盘上的
/// 条目整批删掉。整个库根为空另由 [pruneMissingVideoRows] 拦。
bool isVideoPathInDetachedSubtree(String filePath, String rootPath) {
  final String root = p.normalize(rootPath);
  String dir = p.dirname(p.normalize(filePath));
  while (p.isWithin(root, dir)) {
    final Directory d = Directory(dir);
    if (d.existsSync()) {
      try {
        return d.listSync(followLinks: false).isEmpty;
      } on FileSystemException {
        return true;
      }
    }
    final String parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return false;
}

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
    final String ext = p.extension(e.path).toLowerCase();
    if (!kVideoExtensions.contains(ext) &&
        !kVideoExtensions.contains(ext.replaceFirst('.', ''))) {
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
/// - 失效行所在子树疑似脱挂（[isVideoPathInDetachedSubtree]）→ 该行不判失效；
/// - 失效占比越过 [threshold] → 拒绝。
Future<VideoPruneReport> pruneMissingVideoRows({
  required VideoBookRepository repository,
  required Directory root,
  Set<String>? foundPaths,
  Set<String>? baselineBookUids,
  VideoPruneThreshold threshold = const VideoPruneThreshold(),
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
    return const VideoPruneReport(considered: 0, missing: 0, deleted: 0);
  }
  final bool rootExists = await root.exists();
  // 库根不存在：绝不 prune。NFS 未挂载 / USB 拔掉会把整库删光，
  // 这是本模块最大的事故面。
  if (!rootExists && !force) {
    return VideoPruneReport(
      considered: candidates.length,
      missing: 0,
      deleted: 0,
      skipped: true,
      skipReason: 'library root missing: ${root.path}',
    );
  }
  final Set<String> found =
      foundPaths ??
      (rootExists ? await enumerateLocalVideoPaths(root) : <String>{});
  // 库根在、但一个视频都没有：空挂载点和「用户删光了」长得一样，而前者删错的代价
  // 是整库的进度与刮削身份。小库也拦（比例护栏的绝对下限在这里不适用）。
  if (found.isEmpty && !force) {
    return VideoPruneReport(
      considered: candidates.length,
      missing: 0,
      deleted: 0,
      skipped: true,
      skipReason: 'library root has no video files (unmounted?): ${root.path}',
    );
  }
  final List<VideoBookRow> missingRows = selectStaleVideoRows(
    candidates: candidates,
    foundPaths: found,
    exists: exists,
  );
  final List<VideoBookRow> stale = <VideoBookRow>[
    for (final VideoBookRow row in missingRows)
      if (force || !isVideoPathInDetachedSubtree(row.videoPath, root.path)) row,
  ];
  final int unreachable = missingRows.length - stale.length;
  if (stale.isEmpty) {
    return VideoPruneReport(
      considered: candidates.length,
      missing: 0,
      deleted: 0,
      unreachable: unreachable,
    );
  }
  if (!force &&
      threshold.exceeded(stale: stale.length, considered: candidates.length)) {
    return VideoPruneReport(
      considered: candidates.length,
      missing: stale.length,
      deleted: 0,
      unreachable: unreachable,
      skipped: true,
      skipReason:
          'stale ${stale.length}/${candidates.length} exceeds threshold '
          '(ratio ${threshold.ratio}, floor ${threshold.absoluteFloor}); '
          'pass force to override',
    );
  }
  if (dryRun) {
    return VideoPruneReport(
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
    return VideoPruneReport(
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
  return VideoPruneReport(
    considered: candidates.length,
    missing: stale.length,
    deleted: deleted,
    unreachable: unreachable,
    errors: errors,
  );
}
