/// 「同步与备份 + 互联」模块门在同步层的**唯一真值**，以及在飞同步的协作式取消
/// （反馈 SJeJd5EEZO 的另一半，#3105 遗留）。
///
/// 此前模块门只在 UI 层零散地判（下拉刷新一处、开机自启一处），同步层自己不知道
/// 模块关没关：
/// - 关掉模块时正在跑的同步照常跑完，本次会话的定时同步 / 合集防抖同步也照常跑，
///   要到下次启动才停；
/// - 悬浮球「同步」按钮、桌面控制通道 `sync run` 直接调同步外壳，绕过了门。
///
/// 现在门落在同步层：AppModel 把模块开关同步进 [syncModuleGate]（初始化一次、每次
/// 翻转一次），所有同步入口（开机 / 定时 sweep、手动「立即同步」、资产传输、合集
/// 轻量同步、退出书单本同步）开跑前经 [SyncModuleGate.enter] 领一张 [SyncRunTicket]：
/// 门关着就领不到、不开跑；门在跑的途中关掉，所有在飞的票被标成已取消，同步在下一个
/// **安全检查点**抛 [SyncCancelledException] 收场。
///
/// 检查点只放在「上一项已完整落地、下一项还没开始」的地方（阶段之间、逐项循环的
/// 循环头、拿到锁之后进正文之前），**绝不**打断一项正在进行的判定 + 落地或一次文件
/// 传输：中止留下的状态与一次网络失败在同一位置抛错完全同形（锁在 finally 里释放、
/// 临时文件在各自的 finally 里删、冷却戳 `lastSyncMs` 只在整轮跑完才写），而这些
/// 位置本就要承受网络失败。
library;

import 'package:flutter/foundation.dart';

/// 同步因模块被关掉而在安全检查点中止。各同步入口把它记成
/// `SyncOutcomeReason.cancelled`，不当成失败（不推进失败退避、不记错误）。
class SyncCancelledException implements Exception {
  const SyncCancelledException();

  @override
  String toString() => 'SyncCancelledException: sync module was turned off';
}

/// 一轮同步的取消信号（只读视图）。编排器与各入口只看它，不碰门本身。
abstract interface class SyncCancellation {
  /// 永不取消（测试与不经门的内部调用用）。
  static const SyncCancellation never = _NeverCancelled();

  bool get isCancelled;

  /// 已取消则抛 [SyncCancelledException]。只能在安全检查点调用（见库文档）。
  void throwIfCancelled();
}

class _NeverCancelled implements SyncCancellation {
  const _NeverCancelled();

  @override
  bool get isCancelled => false;

  @override
  void throwIfCancelled() {}
}

/// 一轮同步从 [SyncModuleGate.enter] 领到的票。结束时必须 [leave]（同步任务表的
/// `SyncTaskHandle.finish` 统一代办）。
class SyncRunTicket implements SyncCancellation {
  SyncRunTicket._(this._gate);

  final SyncModuleGate _gate;
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  @override
  void throwIfCancelled() {
    if (_cancelled) throw const SyncCancelledException();
  }

  /// 这一轮结束（无论怎么结束）。重复调用无害。
  void leave() => _gate._live.remove(this);
}

/// 模块门本体。单 isolate 语义：开关翻转与领票之间没有被插队的窗口。
class SyncModuleGate {
  final ValueNotifier<bool> _open = ValueNotifier<bool>(true);
  final Set<SyncRunTicket> _live = <SyncRunTicket>{};

  /// 门此刻是否开着。AppModel 装配之前默认开（fail-open，与模块默认开启一致）。
  bool get isOpen => _open.value;

  /// 门的开合（调度方据此暂停 / 恢复）。
  ValueListenable<bool> get openListenable => _open;

  /// 由模块开关驱动：关门时把所有在飞的票标成已取消；开门只影响之后的领票。
  void setOpen(bool open) {
    if (_open.value == open) return;
    _open.value = open;
    if (open) return;
    for (final SyncRunTicket ticket in _live) {
      ticket._cancelled = true;
    }
  }

  /// 领一张票开跑一轮同步；门关着返回 null（调用方不得开跑）。
  SyncRunTicket? enter() {
    if (!_open.value) return null;
    final SyncRunTicket ticket = SyncRunTicket._(this);
    _live.add(ticket);
    return ticket;
  }

  /// 在飞（已领票未结束）的轮数（测试观察点）。
  @visibleForTesting
  int get liveCount => _live.length;
}

/// 全部同步入口共用的那一道门。
final SyncModuleGate syncModuleGate = SyncModuleGate();

/// 测试用：开门并清空在飞票（模块级状态在测试间必须可复位）。
@visibleForTesting
void resetSyncModuleGateForTest() {
  syncModuleGate._live.clear();
  syncModuleGate._open.value = true;
}
