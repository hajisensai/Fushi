import 'package:hibiki/src/sync/ttu_filename.dart';

/// 用户对「检测到同名书籍」弹窗的选择。
///
/// 值域与 [DuplicatePolicy] 的策略词对齐（`suffix` / `cancel`），不再叫
/// `addSuffix`——同一个概念在策略侧叫 suffix、在选择侧叫 addSuffix，读代码时要
/// 多绕一次。
enum DuplicateChoice { suffix, cancel }

/// 用户选择「否/取消添加这本书」时由 [resolveDuplicateTitle] 抛出，
/// 供导入流程干净地中止（不当作错误）。
///
/// [DuplicatePolicy.skip] 命中时也抛它——批量路径把「跳过」表达成同一个中止信号，
/// 上层 `runImport(isCancelled:)` 已按取消（而非错误）处理，无需第二套通道。
class DuplicateImportCancelledException implements Exception {
  const DuplicateImportCancelledException(this.title);
  final String title;
  @override
  String toString() => 'DuplicateImportCancelledException($title)';
}

/// 同名冲突询问回调：入参是拟用标题，返回用户选择。
typedef AskOnDuplicate = Future<DuplicateChoice> Function(String proposedTitle);

/// 重复条目的**处置策略**。三态互斥，且必须显式选一个。
///
/// ## 为什么是一个参数而不是两个
///
/// 此前这三态由 `(bool skipIfExists, AskOnDuplicate? onDuplicateTitle)` 两个参数
/// 编码：`skipIfExists=true` → 跳过；回调非空 → 询问；两者都缺 → 加后缀。两个参数
/// 有四种组合但只有三种合法，第四种（`skipIfExists=true` 且回调非空）的行为从没被
/// 写下来过（实现里跳过赢），调用方只能靠读实现推理。而且哪个导入器支持哪个参数还不
/// 齐：`importFromImageFolder` / `importArchive` 只有回调、没有 skip，于是批量扫描
/// 压根用不了它们。
///
/// 收敛成一个 sealed 三态后：非法组合不可表达，[resolveDuplicateTitle] 里是穷尽
/// switch（不写 default），将来加第四种策略会在所有分派点编译报错，而不是悄悄走进
/// 某个 else。
///
/// ## 三种策略各自的适用场景（差异是**有意**的，不要再往一起合）
///
/// - [DuplicatePolicy.ask]：交互式**单条**导入（书籍/漫画导入对话框）。用户就在屏幕
///   前，问得起，而且他确实想知道库里已经有一本同名的。
/// - [DuplicatePolicy.skip]：**批量 / 后台**导入（来源库扫描、mokuro.moe 批量下载、
///   torrent 下载完自动入库）。扫一个目录弹五十次框等于不可用（BUG-443）。
/// - [DuplicatePolicy.suffix]：**程序化**路径（同步引擎拉书等）。没有人可问，又必须
///   保住「本地不出现两本同 key 书」这个同步层依赖的不变量，只能留副本。
sealed class DuplicatePolicy {
  const DuplicatePolicy();

  /// 交互式单条导入：把拟用标题交给用户裁决。
  const factory DuplicatePolicy.ask(AskOnDuplicate ask) = AskDuplicate;

  /// 批量 / 后台导入：命中已有条目直接跳过（抛
  /// [DuplicateImportCancelledException]），既不加后缀也不询问。
  const factory DuplicatePolicy.skip() = SkipDuplicate;

  /// 静默留副本：自动加 ` (2)` 后缀。程序化路径的默认。
  const factory DuplicatePolicy.suffix() = SuffixDuplicate;
}

/// [DuplicatePolicy.ask] 的实现类型。
final class AskDuplicate extends DuplicatePolicy {
  const AskDuplicate(this.ask);

  /// 询问用户的回调。
  final AskOnDuplicate ask;
}

/// [DuplicatePolicy.skip] 的实现类型。
final class SkipDuplicate extends DuplicatePolicy {
  const SkipDuplicate();
}

/// [DuplicatePolicy.suffix] 的实现类型。
final class SuffixDuplicate extends DuplicatePolicy {
  const SuffixDuplicate();
}

/// 返回最终入库标题。书籍跨设备身份 = `sanitizeTtuFilename(title)`（同步远端
/// 文件夹 key）。[proposedTitle] 的身份 key 与 [existingTitles] 无冲突时原样返回；
/// 冲突时按 [policy] 处置。
Future<String> resolveDuplicateTitle({
  required List<String> existingTitles,
  required String proposedTitle,
  DuplicatePolicy policy = const DuplicatePolicy.suffix(),
}) async {
  final Set<String> keys = existingTitles.map(sanitizeTtuFilename).toSet();
  if (!keys.contains(sanitizeTtuFilename(proposedTitle))) {
    return proposedTitle;
  }
  // 穷尽 switch，不写 default：加第四种策略时这里会编译报错，而不是悄悄落进某个分支。
  switch (policy) {
    case SkipDuplicate():
      throw DuplicateImportCancelledException(proposedTitle);
    case AskDuplicate(:final AskOnDuplicate ask):
      if (await ask(proposedTitle) == DuplicateChoice.cancel) {
        throw DuplicateImportCancelledException(proposedTitle);
      }
      return _uniqueSuffixedTitle(proposedTitle, keys);
    case SuffixDuplicate():
      return _uniqueSuffixedTitle(proposedTitle, keys);
  }
}

String _uniqueSuffixedTitle(String base, Set<String> existingKeys) {
  for (int i = 2;; i++) {
    final String candidate = '$base ($i)';
    if (!existingKeys.contains(sanitizeTtuFilename(candidate))) {
      return candidate;
    }
  }
}
