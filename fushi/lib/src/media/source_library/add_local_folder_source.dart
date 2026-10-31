import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_folder_access.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';

/// 把一个**本地文件夹**登记成常驻扫描根并立即扫一遍。
///
/// 抽成共享函数而不是让各拖放落点各写一份：书 / 视频 / 漫画三个页面的拖入目录必须
/// 产出**完全相同**的来源行（同样的归一化路径、同样的默认标签、同样的去重判据、同样
/// 的插入后立即扫描），否则各表面会漂成几套语义。
///
/// ⚠ 来源页的「添加本地文件夹」按钮**没有**走这里，它是
/// [MediaSourcesViewState.addLocalFolder] 里的另一份实现（多一步 `_pickVideoGroupingMode`
/// 询问、去重查已加载的 `_rows` 而不是 DB、撞重复时会重扫已有行）。两份的**去重判据**
/// （同 transport + 同归一化 rootPath）必须保持一致——改这里记得同步那边。
///
/// 返回值：
/// - [AddLocalFolderOutcome.added]：新来源行已插入并扫描完成，[rootPath] 是归一化后
///   的路径。
/// - [AddLocalFolderOutcome.duplicate]：同 transport+路径的来源已存在，未做任何写入。
///
/// [mediaKind] 取 `SourceLibraryKind` 的字符串值（`book` / `video` / `manga`）——
/// 由**当前打开的页面**决定，不从文件内容猜。
///
/// [bookmark]：iOS 安全作用域书签（BUG-3697）。现有调用方（拖放落点、桌面控制通道）
/// 都只在桌面 / 安卓可达（desktop_drop 没有 iOS 实现），恒传 null；若将来在 iOS 上
/// 不带书签调用，扫描会如实报「未保存访问授权」而不是静默扫出 0 个。
Future<AddLocalFolderResult> addLocalFolderAsSource({
  required FushiDatabase db,
  required String mediaKind,
  required String path,
  String videoGroupingMode = 'series',
  String? bookmark,
}) async {
  final String norm = normalizeSourceRootPath(path, transport: 'local');
  final List<MediaSourceRow> existing = await db.getMediaSourcesByKind(
    mediaKind,
  );
  final bool duplicate = existing.any(
    (MediaSourceRow r) => r.transport == 'local' && r.rootPath == norm,
  );
  if (duplicate) {
    return AddLocalFolderResult(
      outcome: AddLocalFolderOutcome.duplicate,
      rootPath: norm,
    );
  }
  final int sortOrder = _nextSortOrder(existing);
  final int newId = await db.insertMediaSource(
    MediaSourcesCompanion(
      label: Value(defaultLabelFromRoot(norm, transport: 'local')),
      mediaKind: Value(mediaKind),
      transport: const Value('local'),
      rootPath: Value(norm),
      configJson: sourceConfigValueForBookmark(bookmark),
      recursive: const Value(true),
      videoGroupingMode: Value(videoGroupingMode),
      sortOrder: Value(sortOrder),
      createdAt: Value(DateTime.now().millisecondsSinceEpoch),
    ),
  );
  // 插入后立刻扫描：不扫的话来源列表里是一条 0 媒体的空行，用户以为没生效。
  final SourceLibraryRow? fresh = await db.getMediaSourceById(newId);
  if (fresh != null) {
    await SourceLibraryScanner(db).scan(fresh);
  }
  return AddLocalFolderResult(
    outcome: AddLocalFolderOutcome.added,
    rootPath: norm,
    sourceId: newId,
  );
}

int _nextSortOrder(List<MediaSourceRow> existing) => existing.isEmpty
    ? 0
    : existing
              .map((MediaSourceRow r) => r.sortOrder)
              .reduce((int a, int b) => a > b ? a : b) +
          1;

/// 「导入文件夹（仅此一次）」：与常驻来源共用**同一条**扫描-导入管线，但登记的来源行
/// 只作为这一次扫描的载体，扫完即删——已导入媒体保留（FK setNull 把 sourceId 归
/// NULL，等价于手动单件导入），不留下常驻扫描根。
///
/// 来源页的「仅此一次」与音频 CD 抓轨导入（BUG-3312）共用这一份。抓好的 CD 落在数据根
/// 内，而 `MediaSources.rootPath` 的契约是「数据根之外的外部目录，迁移不改写」，所以它
/// 只能走这里、不能登记成常驻来源。
///
/// [onScanning] 在临时行插入后、扫描开始前回调其 id（来源页用它点亮忙态）。scanner
/// 意外抛出时异常照常上抛，临时行仍会被删除。
///
/// [bookmark]：iOS 安全作用域书签（BUG-3697），只撑这一次扫描的访问窗口，删临时行
/// 前释放。书 / 漫画扫描时已拷进 app，扫完即可停；视频是原地引用，扫完停掉访问后
/// 原文件在 iOS 上不可再读——要长期播放请登记成常驻来源。
Future<SourceScanSummary?> importLocalFolderOnceAt({
  required FushiDatabase db,
  required String mediaKind,
  required String path,
  String videoGroupingMode = 'series',
  String? bookmark,
  void Function(int sourceId)? onScanning,
}) async {
  final String norm = normalizeSourceRootPath(path, transport: 'local');
  final int sortOrder = _nextSortOrder(
    await db.getMediaSourcesByKind(mediaKind),
  );
  final int tempId = await db.insertMediaSource(
    MediaSourcesCompanion(
      label: Value(defaultLabelFromRoot(norm, transport: 'local')),
      mediaKind: Value(mediaKind),
      transport: const Value('local'),
      rootPath: Value(norm),
      configJson: sourceConfigValueForBookmark(bookmark),
      recursive: const Value(true),
      videoGroupingMode: Value(videoGroupingMode),
      sortOrder: Value(sortOrder),
      createdAt: Value(DateTime.now().millisecondsSinceEpoch),
    ),
  );
  try {
    final SourceLibraryRow? temp = await db.getMediaSourceById(tempId);
    if (temp == null) return null;
    onScanning?.call(tempId);
    return await SourceLibraryScanner(db).scan(temp);
  } finally {
    await SourceFolderAccess.instance.release(tempId);
    await db.deleteMediaSource(tempId);
  }
}

enum AddLocalFolderOutcome { added, duplicate }

class AddLocalFolderResult {
  const AddLocalFolderResult({
    required this.outcome,
    required this.rootPath,
    this.sourceId,
  });

  final AddLocalFolderOutcome outcome;

  /// 归一化后的扫描根路径（提示语要显示它，而不是用户拖进来的原始串）。
  final String rootPath;

  /// 仅 [AddLocalFolderOutcome.added] 时非空。
  final int? sourceId;
}
