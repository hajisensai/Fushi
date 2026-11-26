/// 排队覆盖（`queueOverwrite` 桥）回执的值类型。
///
/// 单独成叶子文件：galgame 浮窗的后台写卡登记（`lookup/overlay_queued_mines.dart`）只要这两个
/// 值类型，从 `dictionary_popup_webview.dart`（读 AppModel 的 WebView 层）取会把它拖进 lib/ 的
/// import 大环（`test/build/import_cycle_guard_test.dart`）。`dictionary_popup_webview.dart`
/// 原样 re-export，既有调用方不变。
library;

/// BUG-3492：排队覆盖（`queueOverwrite` 桥）的回执。
///
/// [accepted] = 宿主收下了这次覆盖，会在后台写入落地后执行；[message] 是给弹窗就地
/// 提示的文案（收下时说「写入后自动覆盖」，不收时说为什么）。null 时 popup.js 用
/// 通用的「还没写进 Anki」文案。
class QueuedOverwriteReply {
  const QueuedOverwriteReply({
    this.accepted = false,
    this.message,
    this.settled,
  });

  final bool accepted;
  final String? message;

  /// 宿主没收下、因为这次后台写入**已经结束**了（弹窗问 Anki 与请求到达宿主之间
  /// 落地 / 失败）：popup.js 据此走已制卡的正常覆盖路径（[QueuedOverwriteSettled.landed]）
  /// 或撤掉「已加入」（[QueuedOverwriteSettled.failed]），而不是说「还在写入」。
  final QueuedOverwriteSettled? settled;

  Map<String, Object?> toJson() => <String, Object?>{
    'accepted': accepted,
    if (message != null) 'message': message,
    if (settled != null) 'settled': settled!.name,
  };
}

/// [QueuedOverwriteReply.settled]：那次后台写入的结局。
enum QueuedOverwriteSettled {
  /// 写进了 Anki。
  landed,

  /// 没写进去。
  failed,
}
