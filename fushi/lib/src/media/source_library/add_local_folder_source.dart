import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';

/// 把一个**本地文件夹**登记成常驻扫描根并立即扫一遍。
///
/// 抽成共享函数而不是让各调用点各写一份：来源页的「添加本地文件夹」按钮和拖放落点
/// 必须产出**完全相同**的来源行（同样的归一化路径、同样的默认标签、同样的去重判据、
/// 同样的插入后立即扫描），否则两条入口会漂成两套语义。
///
/// 返回值：
/// - [AddLocalFolderOutcome.added]：新来源行已插入并扫描完成，[rootPath] 是归一化后
///   的路径。
/// - [AddLocalFolderOutcome.duplicate]：同 transport+路径的来源已存在，未做任何写入。
///
/// [mediaKind] 取 `SourceLibraryKind` 的字符串值（`book` / `video` / `manga`）——
/// 由**当前打开的页面**决定，不从文件内容猜。
Future<AddLocalFolderResult> addLocalFolderAsSource({
  required FushiDatabase db,
  required String mediaKind,
  required String path,
}) async {
  final String norm = normalizeSourceRootPath(path, transport: 'local');
  final List<MediaSourceRow> existing =
      await db.getMediaSourcesByKind(mediaKind);
  final bool duplicate = existing
      .any((MediaSourceRow r) => r.transport == 'local' && r.rootPath == norm);
  if (duplicate) {
    return AddLocalFolderResult(
        outcome: AddLocalFolderOutcome.duplicate, rootPath: norm);
  }
  final int sortOrder = existing.isEmpty
      ? 0
      : existing
              .map((MediaSourceRow r) => r.sortOrder)
              .reduce((int a, int b) => a > b ? a : b) +
          1;
  final int newId = await db.insertMediaSource(
    MediaSourcesCompanion(
      label: Value(defaultLabelFromRoot(norm, transport: 'local')),
      mediaKind: Value(mediaKind),
      transport: const Value('local'),
      rootPath: Value(norm),
      recursive: const Value(true),
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
      outcome: AddLocalFolderOutcome.added, rootPath: norm, sourceId: newId);
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
