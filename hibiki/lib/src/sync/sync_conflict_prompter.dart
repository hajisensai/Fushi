import 'package:flutter/widgets.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/utils/misc/show_app_dialog.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 冲突来源：决定弹窗的时机约束。
enum ConflictSource { manual, auto, background }

/// 决定冲突弹窗的「是否/此刻弹」+ 会话级防骚扰，并在该弹时经全局 navigatorKey
/// 弹出冲突解决对话框。决策逻辑（[shouldPrompt]）仍是纯函数；[present] 只是把
/// 「该弹就弹、用户没解就静默」这条策略接到真实 UI 上。纯内存、随会话失效。
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

  /// 按 [shouldPrompt] 决策，必要时经全局 [navigatorKey] 弹出 conflictsOnly 的
  /// 冲突解决对话框。用户未解决（applied 计数为空/0）则把这组冲突指纹加入会话
  /// snooze，避免自动同步反复打扰。
  ///
  /// 直接渲染 [SyncCompareDialog]（注入已解析的 [backend]），而非走
  /// [showSyncCompareDialog] —— 后者从 db 自行解析 backend 且不回传 applied
  /// 计数，无法满足「用注入 backend + 观察是否已解决以决定 snooze」这两点。
  Future<void> present({
    required GlobalKey<NavigatorState> navigatorKey,
    required HibikiDatabase db,
    required SyncBackend backend,
    required List<SyncConflict> conflicts,
    required ConflictSource source,
    required bool inBook,
  }) async {
    if (!shouldPrompt(conflicts: conflicts, source: source, inBook: inBook)) {
      return;
    }
    final BuildContext? ctx = navigatorKey.currentContext;
    if (ctx == null) return; // HBK-AUDIT-012：navigatorKey 未 attach 时 null 安全
    dialogOpen = true;
    try {
      final int? applied = await showAppDialog<int>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => SyncCompareDialog(
          db: db,
          backend: backend,
          conflictsOnly: true,
        ),
      );
      // applied>0 表示用户至少解决了一项；否则视为取消，本会话静默这组冲突。
      if (applied == null || applied <= 0) markDismissed(conflicts);
    } finally {
      dialogOpen = false;
    }
  }
}
