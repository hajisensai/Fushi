import 'package:hibiki/src/sync/ttu_filename.dart';

/// 用户对"检测到同名书籍"弹窗的选择。
enum DuplicateTitleResolution { addSuffix, cancel }

/// 用户选择"否/取消添加这本书"时由 [resolveBookTitleConflict] 抛出，
/// 供导入流程干净地中止（不当作错误）。
class DuplicateImportCancelledException implements Exception {
  const DuplicateImportCancelledException(this.title);
  final String title;
  @override
  String toString() => 'DuplicateImportCancelledException($title)';
}

/// 同名冲突回调：入参是拟用标题，返回用户选择。
typedef DuplicateTitleCallback = Future<DuplicateTitleResolution> Function(
  String proposedTitle,
);

/// 返回最终入库标题。书籍跨设备身份 = `sanitizeTtuFilename(title)`（同步远端
/// 文件夹 key）。若 [proposedTitle] 的身份 key 与 [existingTitles] 任一冲突：
/// 有回调则询问——addSuffix 返回唯一后缀标题（`X (2)`），cancel 抛
/// [DuplicateImportCancelledException]；无回调则自动加后缀（保持"本地不出现
/// 两本同 key 书"这一同步层依赖的不变量，供后台同步/程序化调用安全使用）。
///
/// [skipIfExists] 为 true 时（文件夹扫描器的静默去重路径，BUG-443）：身份 key
/// 命中已存在书时直接抛 [DuplicateImportCancelledException]（不加后缀、不询问），
/// 让批量扫描像视频 `_importVideos` 那样静默跳过同名书，避免静默复制成 `X (2)`。
/// 不影响单文件手动导入路径（默认 false，保留原弹窗/自动后缀语义）。
Future<String> resolveBookTitleConflict({
  required List<String> existingTitles,
  required String proposedTitle,
  DuplicateTitleCallback? onDuplicateTitle,
  bool skipIfExists = false,
}) async {
  final Set<String> keys = existingTitles.map(sanitizeTtuFilename).toSet();
  if (!keys.contains(sanitizeTtuFilename(proposedTitle))) {
    return proposedTitle;
  }
  if (skipIfExists) {
    throw DuplicateImportCancelledException(proposedTitle);
  }
  if (onDuplicateTitle != null) {
    final DuplicateTitleResolution res = await onDuplicateTitle(proposedTitle);
    if (res == DuplicateTitleResolution.cancel) {
      throw DuplicateImportCancelledException(proposedTitle);
    }
  }
  return _uniqueSuffixedTitle(proposedTitle, keys);
}

String _uniqueSuffixedTitle(String base, Set<String> existingKeys) {
  for (int i = 2;; i++) {
    final String candidate = '$base ($i)';
    if (!existingKeys.contains(sanitizeTtuFilename(candidate))) {
      return candidate;
    }
  }
}
