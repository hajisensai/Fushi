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
    this.skipped = false,
    this.skipReason,
    this.errors = const <String>[],
  });

  /// 候选行数（落在 root 内、非网络流）。
  final int considered;

  /// 其中文件确已不存在的行数。
  final int missing;

  /// 实际删除的行数。
  final int deleted;

  /// 是否被护栏 / 刮削租约拦下（未执行删除）。
  final bool skipped;
  final String? skipReason;
  final List<String> errors;

  @override
  String toString() => skipped
      ? 'prune skipped ($skipReason; considered $considered, missing $missing)'
      : 'pruned $deleted/$missing (considered $considered)';
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
    if (foundPaths.contains(normalizeVideoPath(primary))) continue;
    if (fileExists(primary)) continue;
    stale.add(row);
  }
  return stale;
}

/// 对 [root] 下的视频库做一次对账：挑出文件已消失的行并回收。
///
/// [foundPaths] 为空时自行枚举（调用方已经枚举过就传进来，避免重复遍历磁盘）。
/// [dryRun] 只算不删（返回的 `missing` 即计划删除数，`deleted` 恒 0）。
Future<VideoPruneReport> pruneMissingVideoRows({
  required VideoBookRepository repository,
  required Directory root,
  Set<String>? foundPaths,
  VideoPruneThreshold threshold = const VideoPruneThreshold(),
  bool force = false,
  bool dryRun = false,
  bool Function(String path)? exists,
}) async {
  final List<VideoBookRow> candidates = videoRowsWithinRoot(
    await repository.listAll(),
    root.path,
  );
  if (candidates.isEmpty) {
    return const VideoPruneReport(considered: 0, missing: 0, deleted: 0);
  }
  // 库根不存在：绝不 prune。NFS 未挂载 / USB 拔掉 / 空挂载点会把整库删光，
  // 这是本模块最大的事故面。
  if (!await root.exists()) {
    return VideoPruneReport(
      considered: candidates.length,
      missing: 0,
      deleted: 0,
      skipped: true,
      skipReason: 'library root missing: ${root.path}',
    );
  }
  final Set<String> found = foundPaths ?? await enumerateLocalVideoPaths(root);
  final List<VideoBookRow> stale = selectStaleVideoRows(
    candidates: candidates,
    foundPaths: found,
    exists: exists,
  );
  if (stale.isEmpty) {
    return VideoPruneReport(
      considered: candidates.length,
      missing: 0,
      deleted: 0,
    );
  }
  if (!force &&
      threshold.exceeded(stale: stale.length, considered: candidates.length)) {
    return VideoPruneReport(
      considered: candidates.length,
      missing: stale.length,
      deleted: 0,
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
  } on StateError catch (e) {
    // 刮削正在跑（`VideoScrapeOperationGate` 租约拿不到）：不删，如实报告，
    // 不把整个扫描拖垮。
    return VideoPruneReport(
      considered: candidates.length,
      missing: stale.length,
      deleted: 0,
      skipped: true,
      skipReason: '$e',
    );
  } catch (e) {
    errors.add('$e');
  }
  return VideoPruneReport(
    considered: candidates.length,
    missing: stale.length,
    deleted: deleted,
    errors: errors,
  );
}
