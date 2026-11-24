// 反馈 Va3bdT-X0r（BUG-5386 遗留）：app 外查词卡上「已加入制卡队列」的那张卡，后来
// 落地 / 失败 / 重新排队，要推回给还开着的查词卡，就地说出来。
//
// 为什么需要这条推送：gal 查词制卡（台词浮窗点词 + 游戏内查词卡）采样一结束就回
// `queued`，编码与写卡在后台跑（BUG-5386）。写卡阶段的结局以前只走主窗 FushiToast——
// 游戏全屏时主窗压在后面，Anki 没开这类失败用户一个字也看不到，查词卡上还一直挂着
// 「已加入」的 ✓。查词卡是独立的 native WebView2 窗口，宿主没有任何东西能告诉它
// 「这张卡后来失败了」。
//
// 本文件只放纯数据与脚本拼装（不碰 Flutter / 平台通道），推送与重试的派发在
// [GlobalLookupController.settleQueuedMine] / `retryQueuedMine` 桥。
library;

import 'dart:collection';
import 'dart:convert';

/// 一次后台写卡的状态变化。
enum QueuedMineOutcome {
  /// 卡已写进 Anki。
  landed,

  /// 写卡失败（Anki 没开 / 字段映射对不上 / 已存在 …）。
  failed,

  /// 失败后用户点了重试（查词卡上或主窗 toast 上），同一份画面与句音重新排队写入。
  requeued,
}

/// 推给 app 外查词卡的一条结局。popup.js 只按 [job] 认按钮（同一个词在别的卡 / 别的
/// 帧里另起的制卡互不串）。
class QueuedMineSettlement {
  const QueuedMineSettlement({
    required this.job,
    required this.outcome,
    this.noteId,
    this.message,
    this.duplicate = false,
    this.retryable = false,
  });

  /// [QueuedMineJobs.mint] 发的编号，随 `queued` 回包交给 popup.js。
  final int job;
  final QueuedMineOutcome outcome;

  /// 落地时 Anki 给的 note id（AnkiConnect 才有），popup.js 据此标「最新可改」。
  final int? noteId;

  /// 失败原因（宿主算好的本地化整句）。
  final String? message;

  /// 失败是因为 Anki 里已经有这张卡——按钮该画 ✓ 而不是 +（BUG-1908 同口径）。
  final bool duplicate;

  /// 失败后还能用已做好的画面与句音重写（[QueuedMineJobs.armRetry] 已登记）。
  final bool retryable;

  Map<String, Object?> toJson() => <String, Object?>{
    'job': job,
    'outcome': outcome.name,
    if (noteId != null) 'noteId': noteId,
    if (message != null && message!.isNotEmpty) 'message': message,
    if (duplicate) 'duplicate': true,
    if (retryable) 'retryable': true,
  };
}

/// 宿主脚本：交给 global_lookup_host.js 转发进每个已装好的卡片 realm。宿主未装好时是
/// 空操作（与同文件族的 build*Script 同一守卫）。
String buildQueuedMineSettledScript(QueuedMineSettlement settlement) {
  return 'window.__globalLookupHost && '
      'window.__globalLookupHost.queuedMineSettled && '
      'window.__globalLookupHost.queuedMineSettled('
      '${jsonEncode(settlement.toJson())});';
}

/// 后台写卡编号 + 失败后可重试的入口。
///
/// 重试入口是**一次性**的：查词卡上的「重试」与主窗 toast 上的「重试」共用同一个
/// 入口，谁先点谁生效，另一处再点不会再写一张。容量有上限（最老的先出）——一局游戏
/// 里失败未处理的卡堆不起来，也不该无限持有已编码好的媒体。
class QueuedMineJobs {
  QueuedMineJobs({this.capacity = 32});

  final int capacity;
  int _next = 0;
  final LinkedHashMap<int, void Function()> _retries =
      LinkedHashMap<int, void Function()>();

  /// 发一个新编号。
  int mint() => ++_next;

  /// 登记 [job] 的重试入口（覆盖旧的）。
  void armRetry(int job, void Function() retry) {
    _retries.remove(job);
    _retries[job] = retry;
    while (_retries.length > capacity) {
      _retries.remove(_retries.keys.first);
    }
  }

  /// 撤掉 [job] 的重试入口（已落地 / 已重试）。
  void disarm(int job) => _retries.remove(job);

  /// [job] 当前还能不能重试。
  bool canRetry(int job) => _retries.containsKey(job);

  /// 取走并执行 [job] 的重试入口。返回 false = 已失效（已被另一处点过 / 被挤出）。
  bool retry(int job) {
    final void Function()? retry = _retries.remove(job);
    if (retry == null) return false;
    retry();
    return true;
  }
}
