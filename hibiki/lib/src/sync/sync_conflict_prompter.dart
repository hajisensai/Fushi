import 'package:hibiki/src/sync/sync_orchestrator.dart';

/// 冲突来源：决定弹窗的时机约束。
enum ConflictSource { manual, auto, background }

/// 决定冲突弹窗的「是否/此刻弹」+ 会话级防骚扰。纯内存、随会话失效。
/// 只做决策，不持有 UI（弹窗由调用方按本类结论执行）。
class SyncConflictPrompter {
  bool dialogOpen = false;
  final Set<String> _snoozed = <String>{};

  /// 是否此刻应当弹出冲突解决对话框。
  bool shouldPrompt({
    required List<SyncConflict> conflicts,
    required ConflictSource source,
    required bool inBook,
  }) {
    if (conflicts.isEmpty) return false;
    if (dialogOpen) return false; // 单飞：已有对话框
    if (source == ConflictSource.background) return false; // 切后台看不到
    if (source == ConflictSource.auto) {
      if (inBook) return false; // 阅读中不打断
      // 整组都被本会话忽略过才压制；任一新指纹则仍弹。
      final bool allSnoozed =
          conflicts.every((SyncConflict c) => _snoozed.contains(c.fingerprint));
      if (allSnoozed) return false;
    }
    return true; // manual 不受 in-book/snooze 约束
  }

  /// 用户取消/关闭（未解决）后调用：本会话内对这些指纹的 auto 弹窗静默。
  void markDismissed(List<SyncConflict> conflicts) {
    for (final SyncConflict c in conflicts) {
      _snoozed.add(c.fingerprint);
    }
  }
}
