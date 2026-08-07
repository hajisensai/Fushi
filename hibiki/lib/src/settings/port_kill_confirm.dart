import 'package:flutter/material.dart';
import 'package:fushi/src/sync/port_process_terminator.dart';
import 'package:fushi/utils.dart';

/// 「一键结束占用端口的进程」杀前决策结果。
enum PortKillDecisionKind {
  /// 端口已无人占用（或占用者恰是本进程持有）——直接重试启动即可，无需杀。
  noListener,

  /// 占用者是关键系统进程，拒绝结束（调用方给出可见说明）。
  refusedProtected,

  /// 用户在确认弹窗里取消（或弹窗前上下文已失效）——什么都不做。
  cancelled,

  /// 确认期间占用者换人（PID 变化），为避免误杀放弃本次操作。
  listenerChanged,

  /// 用户已确认，可以结束 [PortKillDecision.listener]。
  confirmed,
}

/// [decidePortKill] 的返回值；[listener] 在 [PortKillDecisionKind.noListener]
/// 与 [PortKillDecisionKind.cancelled] 时为 null。
class PortKillDecision {
  const PortKillDecision(this.kind, [this.listener]);

  final PortKillDecisionKind kind;
  final PortListenerInfo? listener;
}

typedef PortListenerFinder = Future<PortListenerInfo?> Function(int port);

/// 杀前确认流程：找出占用者 → 关键系统进程守卫 → 确认弹窗展示占用者
/// （进程名 + PID + 可执行路径；hibiki 自身旧实例特别标注）→ 确认后复核
/// 占用者 PID 未变（确认弹窗把 find→kill 的 TOCTOU 窗口拉长了，换人必须放弃）。
///
/// 只做决策不做杀；[findListener] / [isSelfInstance] 可注入以便 widget 测试
/// （默认走 [PortProcessTerminator.findListener] 与
/// [PortListenerInfo.isSelfInstance]）。
Future<PortKillDecision> decidePortKill(
  BuildContext context, {
  required int port,
  PortListenerFinder findListener = PortProcessTerminator.findListener,
  bool Function(PortListenerInfo listener)? isSelfInstance,
}) async {
  final PortListenerInfo? listener = await findListener(port);
  if (listener == null) {
    return const PortKillDecision(PortKillDecisionKind.noListener);
  }
  if (isProtectedSystemProcess(
    listenerPid: listener.pid,
    processName: listener.processName,
  )) {
    return PortKillDecision(PortKillDecisionKind.refusedProtected, listener);
  }
  if (!context.mounted) {
    return const PortKillDecision(PortKillDecisionKind.cancelled);
  }

  final bool self = isSelfInstance != null
      ? isSelfInstance(listener)
      : listener.isSelfInstance;
  final StringBuffer message = StringBuffer(
    t.yomitan_port_kill_confirm_message(
      process: describePortListener(listener),
    ),
  );
  final String? path = listener.executablePath;
  if (path != null && path.isNotEmpty) {
    message
      ..write('\n')
      ..write(path);
  }
  if (self) {
    message
      ..write('\n\n')
      ..write(t.yomitan_port_kill_self_instance);
  }

  final HibikiDestructiveConfirmResult? confirmed =
      await showAppDialog<HibikiDestructiveConfirmResult>(
    context: context,
    builder: (_) => HibikiDestructiveConfirmDialog(
      title: t.yomitan_port_kill_confirm_title(port: port),
      message: message.toString(),
      confirmLabel: t.yomitan_port_kill_confirm,
      leadingIcon: Icons.stop_circle_outlined,
    ),
  );
  if (confirmed == null) {
    return const PortKillDecision(PortKillDecisionKind.cancelled);
  }

  // 杀前复核：确认弹窗开着期间原占用者可能已退出、PID 也可能被复用/换人。
  // 用户确认的是弹窗里那个进程，PID 变了就不能杀。
  final PortListenerInfo? recheck = await findListener(port);
  if (recheck == null) {
    return const PortKillDecision(PortKillDecisionKind.noListener);
  }
  if (recheck.pid != listener.pid) {
    return PortKillDecision(PortKillDecisionKind.listenerChanged, recheck);
  }
  return PortKillDecision(PortKillDecisionKind.confirmed, listener);
}

/// 占用者展示串：`python.exe (PID 188544)`。
String describePortListener(PortListenerInfo listener) {
  return '${listener.processName} (PID ${listener.pid})';
}
