import 'dart:async';

import 'package:flutter/foundation.dart';

/// 退出书时触发的「关书同步」在飞 Future 的 app-scope 跟踪表（TODO-132 诉求B）。
///
/// 背景与根因：退出书走 [BaseSourcePageState.onWillPop] →
/// `triggerAutoSyncAfterClose`（fire-and-forget，返回 void）→ 内部 `_runAutoSync`
/// 是一个**游离的 async Future**。它跑在事件循环里、由 `sync_auto_trigger.dart` 的
/// 进程级 `_autoSyncMutex` 串行化，本身不阻塞 `onWillPop` 返回，也与触发它的页面
/// 实例无关——页面 widget `dispose()` 之后它照样继续跑（Dart Future 不随 widget
/// 销毁取消）。这正是 HSA（Hoshi-Reader-Android）的契约：退出书 fire-and-forget，
/// export 与页面生命周期解耦，页面销毁后仍跑完。
///
/// 但「游离」也意味着**进程退出路径不知道它的存在**：桌面点 X 走
/// `_flushAndExitForWindowClose`（flush 活跃页面 pending 写 → close DB →
/// `exit(0)` 快杀）。若用户「退出书后立刻杀应用」，这个关书同步的远端传输可能正在
/// 进行（132A/BUG-201 已把 progress baseline 写得与权威进度传输原子，杜绝了「假
/// 冲突」；但内容/统计/有声书等**尾随传输**仍可能被进程终止打成半截）。
///
/// 本注册表把每个在飞的关书同步 Future 登记到一处 app-scope（进程级单例，等同于
/// `_autoSyncMutex` 那样的顶层所有权——不依赖任何页面）。退出路径在 flush 数据后、
/// `exit(0)` 前调用 [drain] **有界等待**这些 Future 落定，使关书同步要么跑完、要么
/// 在上限内放行（绝不无限阻塞退出）。这与 `ExitFlushRegistry` 互补：后者 flush 的是
/// 本地 Drift 写（≤2s、不碰网络），本表 drain 的是网络 export（容许更长上限）。
///
/// 不改变「不阻塞 UI」：[register] 只收集 Future，不让任何调用方 await 它；只有
/// 进程退出这一条路径才 [drain]，且有界。
class BookExitSyncScope {
  BookExitSyncScope._();

  /// 进程级单例。`sync_auto_trigger` 随处登记，退出路径在 main.dart 统一 drain。
  static final BookExitSyncScope instance = BookExitSyncScope._();

  final Set<Future<void>> _inFlight = <Future<void>>{};

  /// drain 的默认硬上限：在飞关书同步卡住（弱网/远端慢）也不得无限拖住退出。
  static const Duration defaultDrainTimeout = Duration(seconds: 8);

  @visibleForTesting
  int get inFlightCount => _inFlight.length;

  /// 登记一个在飞的关书同步 [future]（幂等：同一 Future 实例只记一次）。Future
  /// 完成（成功或失败）后**自动注销**，避免集合无限增长 / 泄漏。
  ///
  /// 注意：不改变 [future] 本身的完成状态——调用方（`_runAutoSync`）已用自己的
  /// try/catch 兜住并记日志，传进来的 future 正常已 resolve 成功。这里挂一条**旁路**
  /// `.then(成功, onError)` 仅做「完成即移除」清理：旁路对成功/失败都注销，且自身
  /// 吞掉错误（不重新抛），以免「注销监听」本身在 future 是 rejected 时变成
  /// unhandled async error 刷屏（true bug：`whenComplete` 会透传 error）。原 future
  /// 的 error 仍由 [drain] 的 `_guard` 在退出时统一处理。返回传入的 [future] 本身，
  /// 便于调用方继续链式使用（不强制 await）。
  Future<void> register(Future<void> future) {
    _inFlight.add(future);
    future.then(
      (_) => _inFlight.remove(future),
      onError: (Object _, StackTrace __) => _inFlight.remove(future),
    );
    return future;
  }

  /// 退出路径调用：有界等待所有在飞关书同步落定。取当前快照并 await，最长
  /// [timeout]；超时则放行（卡住的传输不阻塞退出，由进程终止收尾——远端半截是
  /// 退出快杀的固有代价，远好于无限卡死退出）。任一 Future 抛异常也不影响其余、
  /// 不让 drain 自身抛出（退出清理失败不该阻止退出）。
  Future<void> drain({Duration timeout = defaultDrainTimeout}) async {
    if (_inFlight.isEmpty) return;
    final List<Future<void>> snapshot = _inFlight.toList(growable: false);
    final Future<void> all = Future.wait(
      snapshot.map(_guard),
      eagerError: false,
    );
    try {
      await all.timeout(timeout);
    } on TimeoutException {
      debugPrint(
          '[Hibiki] book-exit sync drain timed out after ${timeout.inSeconds}s; '
          'exiting anyway (remote transfer may be partial)');
    }
  }

  /// 测试用：清空跟踪表（不取消在飞 Future，仅复位单例状态）。
  @visibleForTesting
  void clear() => _inFlight.clear();

  static Future<void> _guard(Future<void> future) async {
    try {
      await future;
    } catch (e) {
      // 单个关书同步失败不该影响 drain 等其余 Future，也不该让退出报错。
      debugPrint('[Hibiki] book-exit sync future failed during drain: $e');
    }
  }
}
