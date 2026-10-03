/// 库扫描对账的**共用护栏**：视频根（`video_library_prune.dart`）与书 / 漫画根
/// （`book_library_prune.dart`）用同一套判据决定「这轮能不能删」。
///
/// 对账是破坏性操作，最大的事故面是「库根只是暂时不可达」（NFS 没挂、USB 拔了、
/// 子挂载点掉线）被当成「用户删光了」。这里集中四条护栏，调用方按同一顺序套用：
/// 1. 库根不存在 → 拒绝（[libraryRootSkipReason]）；
/// 2. 库根在但一个媒体都枚举不到 → 拒绝（空挂载点，同上）；
/// 3. 失效条目所在子树疑似脱挂 → 该条不判失效（[isPathInDetachedSubtree]）；
/// 4. 失效占比越过 [LibraryPruneThreshold] → 拒绝（[LibraryPruneThreshold.skipReason]）。
///
/// `force`（显式用户意图，如「移除并清理」）越过全部四条，只留「源确实不存在」。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 单次对账的护栏阈值：失效占比超过 [ratio] **且**失效数超过 [absoluteFloor] 时
/// 拒绝执行（除非调用方显式 `force`）。
///
/// 两个条件同时成立才拦，是为了让**小库**能被完整清理（用户删光一个小库是正常意图），
/// 而**大库**在「挂载点空了 / NFS 掉了」这类事故下不会被整批删光。[absoluteFloor]
/// 是「多少条以下不设比例门」的绝对下限。
class LibraryPruneThreshold {
  const LibraryPruneThreshold({this.ratio = 0.5, this.absoluteFloor = 10});

  final double ratio;
  final int absoluteFloor;

  /// [stale] / [considered] 是否突破护栏。
  bool exceeded({required int stale, required int considered}) =>
      stale > absoluteFloor && considered > 0 && stale / considered > ratio;

  /// 突破护栏时的说明（写进 [LibraryPruneReport.skipReason]）；未突破返回 null。
  String? skipReason({required int stale, required int considered}) =>
      exceeded(stale: stale, considered: considered)
      ? 'stale $stale/$considered exceeds threshold '
            '(ratio $ratio, floor $absoluteFloor); pass force to override'
      : null;
}

/// 一次对账的结果（视频 / 书 / 漫画共用）。
class LibraryPruneReport {
  const LibraryPruneReport({
    required this.considered,
    required this.missing,
    required this.deleted,
    this.unreachable = 0,
    this.skipped = false,
    this.skipReason,
    this.errors = const <String>[],
  });

  /// 候选条目数（属于该库根；给了基线时只算本轮扫描前就在库里的条目）。
  final int considered;

  /// 其中源确已不存在的条目数。
  final int missing;

  /// 源找不到、但所在子树疑似脱挂（最近的现存上级目录是空的或列不出来）
  /// 而**没有**判失效的条目数。见 [isPathInDetachedSubtree]。
  final int unreachable;

  /// 实际删除的条目数。
  final int deleted;

  /// 是否被护栏 / 租约拦下（未执行删除）。
  final bool skipped;
  final String? skipReason;
  final List<String> errors;

  @override
  String toString() => skipped
      ? 'prune skipped ($skipReason; considered $considered, missing $missing)'
      : 'pruned $deleted/$missing (considered $considered'
            '${unreachable > 0 ? ', unreachable $unreachable' : ''})';
}

/// 护栏 1、2：库根不存在 / 库根在但一个媒体都枚举不到时返回拒绝原因，否则 null。
///
/// 空挂载点和「用户删光了」长得一样，而前者删错的代价是整库的进度与身份，所以
/// 小库也拦（比例护栏的绝对下限在这里不适用）。[mediaNoun] 只进说明文字
/// （如 `video files` / `book files`）。
String? libraryRootSkipReason({
  required String rootPath,
  required bool rootExists,
  required bool foundAny,
  required String mediaNoun,
}) {
  if (!rootExists) return 'library root missing: $rootPath';
  if (!foundAny) {
    return 'library root has no $mediaNoun (unmounted?): $rootPath';
  }
  return null;
}

/// 护栏 3：[entryPath] 所在子树是否疑似「挂载点掉了」：从它的上级目录往上找到第一个
/// 现存目录（不越过 [rootPath]），它若是**空的**或**列不出来**（权限 / IO 错误），就当
/// 不可达而不是「被删」。
///
/// 用户删一整季 / 一整套通常连目录一起删，最近的现存上级是非空的库根或父目录 → 照常
/// 判失效；子挂载点（`/media/disk2`）掉线后留下的是一个空目录 → 这里拦住，不把那块盘
/// 上的条目整批删掉。整个库根为空另由 [libraryRootSkipReason] 拦。
bool isPathInDetachedSubtree(String entryPath, String rootPath) {
  final String root = p.normalize(rootPath);
  String dir = p.dirname(p.normalize(entryPath));
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
