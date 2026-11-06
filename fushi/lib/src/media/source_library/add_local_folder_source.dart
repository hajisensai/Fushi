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
/// - [AddLocalFolderOutcome.duplicate]：同 transport+路径的来源已存在（[sourceId] 是那一
///   行），没有新插入；手动添加撞上自动来源时只把它转成手动来源。
///
/// [mediaKind] 取 `SourceLibraryKind` 的字符串值（`book` / `video` / `manga` /
/// `music`）——由**当前打开的页面**决定，不从文件内容猜；唯一例外是视频来源里扫到的
/// 纯音频交给音乐库（`music_audio_intake.dart`，反馈 QAondMh4M5），那里登记 `music`。
///
/// [recursive]：来源行的「含子文件夹」。拖放 / 来源页默认递归；音乐库收视频来源里的
/// 纯音频时，目录的子树里有视频就只收这一层（见 `music_audio_roots.dart`）。
///
/// [bookmark]：iOS 安全作用域书签（BUG-3697）。现有调用方（拖放落点、桌面控制通道）
/// 都只在桌面 / 安卓可达（desktop_drop 没有 iOS 实现），恒传 null；若将来在 iOS 上
/// 不带书签调用，扫描会如实报「未保存访问授权」而不是静默扫出 0 个。音乐库自动登记的
/// 来源（[autoOwnerSourceId] 非空）不带书签：iOS 上扫描时借 owner 视频来源的访问授权
/// （`SourceFolderAccess`，自动来源根恒在 owner 根之下）。
///
/// [autoOwnerSourceId]：音乐库收视频来源里的纯音频时，记下是哪个视频来源登记的（v145，
/// 删视频来源时连带移除）。null = 用户手动添加：撞上同根的**自动**来源时把它转成手动
/// 来源（之后删视频来源它也留着），并解除所有视频来源对这个目录的「不再登记」。
Future<AddLocalFolderResult> addLocalFolderAsSource({
  required FushiDatabase db,
  required String mediaKind,
  required String path,
  String videoGroupingMode = 'series',
  String? bookmark,
  bool recursive = true,
  int? autoOwnerSourceId,
}) async {
  final String norm = normalizeSourceRootPath(path, transport: 'local');
  final List<MediaSourceRow> existing = await db.getMediaSourcesByKind(
    mediaKind,
  );
  final MediaSourceRow? duplicate = existing
      .where((MediaSourceRow r) => sameLocalSourceRoot(r, norm))
      .firstOrNull;
  if (autoOwnerSourceId == null) {
    await claimLocalSourceRootAsManual(db, mediaKind, norm, duplicate);
  }
  if (duplicate != null) {
    return AddLocalFolderResult(
      outcome: AddLocalFolderOutcome.duplicate,
      rootPath: norm,
      sourceId: duplicate.id,
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
      recursive: Value(recursive),
      videoGroupingMode: Value(videoGroupingMode),
      sortOrder: Value(sortOrder),
      createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      autoOwnerSourceId: Value(autoOwnerSourceId),
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

/// 两份「添加本地文件夹」（这里与来源页 `MediaSourcesViewState.addLocalFolder`）共用的
/// 去重判据：同 transport（本地）+ 同归一化根。
bool sameLocalSourceRoot(MediaSourceRow row, String normalizedRoot) =>
    row.transport == 'local' && row.rootPath == normalizedRoot;

/// 用户**手动**添加本地目录 [normalizedRoot]（v145，反馈 QAondMh4M5）：撞上的同根来源
/// [duplicate] 是视频来源自动登记的音乐来源时转成手动来源（以后删视频来源也留着）；
/// 并解除所有视频来源对这个目录的「不再登记」（用户明确要它）。两份「添加本地文件夹」
/// 都调这一个函数。只对音乐来源有意义，其余种类是空操作。
Future<void> claimLocalSourceRootAsManual(
  FushiDatabase db,
  String mediaKind,
  String normalizedRoot,
  MediaSourceRow? duplicate,
) async {
  if (mediaKind != SourceLibraryKind.music.dbValue) return;
  if (duplicate != null && duplicate.autoOwnerSourceId != null) {
    await db.setMediaSourceAutoOwner(duplicate.id, null);
  }
  await db.clearMusicAutoSourceDismissalsForRoot(normalizedRoot);
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
/// 音乐库的单文件导入也走这里：[mediaKind] = `music` 时 [path] 可以是**单个音频文件**
/// （Rust 扫描器接受文件根，只收这一个文件；`music_audio_intake.dart`）。曲目行不挂
/// 来源外键，临时行删掉后曲目照常留在曲库。
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
  bool recursive = true,
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
      recursive: Value(recursive),
      videoGroupingMode: Value(videoGroupingMode),
      sortOrder: Value(sortOrder),
      createdAt: Value(DateTime.now().millisecondsSinceEpoch),
    ),
  );
  try {
    final SourceLibraryRow? temp = await db.getMediaSourceById(tempId);
    if (temp == null) return null;
    onScanning?.call(tempId);
    return await SourceLibraryScanner(db).scan(temp, oneShot: true);
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

  /// [AddLocalFolderOutcome.added]：新行；[AddLocalFolderOutcome.duplicate]：已有的那一行。
  final int? sourceId;
}
