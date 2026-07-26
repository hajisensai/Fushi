// spec 2026-07-10 剪贴板独立弹窗 — 桌面查词请求的去向路由（纯函数）。
//
// HomeDictionaryPage（mainTab）与 DesktopLookupDispatcher（panel/transient）
// 都用 [resolveDesktopLookupConsumer] 对同一个 pendingRequest 做互斥分区：
// 判定不属于自己分区的请求一律不消费，故永不双消费、永不丢请求。

import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

/// 桌面查词请求的消费面（spec 2026-07-10 §4）。
/// textWindow = 真透明剪切板文字窗（复用 FloatingLyricWindow 第二实例，text-only）。
enum DesktopLookupConsumer { mainTab, panel, transient, textWindow }

/// 纯函数：一次 [DesktopLookupService] 请求应落到哪个消费面。
/// - explicit（悬浮字幕点词回落）恒 mainTab：它本就是覆盖窗不可用时的回落路径，
///   覆盖窗可用时悬浮字幕点词根本不会走到 DesktopLookupService。
/// - 覆盖窗不可用（非 Windows / 控制器未启动）时 panel/transient 退回 mainTab，
///   请求永不静默丢失。
DesktopLookupConsumer resolveDesktopLookupConsumer({
  required DesktopLookupOrigin origin,
  required DesktopClipboardDestination destination,
  required bool overlayAvailable,
}) {
  if (origin == DesktopLookupOrigin.explicit) {
    return DesktopLookupConsumer.mainTab;
  }
  if (!overlayAvailable) return DesktopLookupConsumer.mainTab;
  switch (destination) {
    case DesktopClipboardDestination.main:
      return DesktopLookupConsumer.mainTab;
    case DesktopClipboardDestination.panel:
      return DesktopLookupConsumer.panel;
    case DesktopClipboardDestination.transient:
      return DesktopLookupConsumer.transient;
    case DesktopClipboardDestination.textWindow:
      return DesktopLookupConsumer.textWindow;
  }
}

/// BUG-1099 纯判据：一条**被动文本流**请求到达时，是否保留用户已点出的那张卡
/// （只换句子横幅 / 直接忽略），而不是整帧重建 root。
///
/// 单一真相源，面板（[ClipboardPanelController.update]）与瞬态覆盖窗
/// （[GlobalLookupController.lookupText]）共用，两条出口的抢占语义不会漂开。
///
/// 三个条件缺一不可：
/// - [passiveStream]：请求来自**环境剪贴板监听**（用户没有对 Hibiki 做任何动作，
///   见 [DesktopLookupService.processClipboardText]），而不是热键 / 悬浮字幕点词
///   这类显式意图。显式意图恒重建，绝不被这条保护锁死。
/// - [userOwnedCard]：当前这张卡是用户**自己点出来的**（面板横幅点字 /
///   卡内点词压栈 / 台词浮窗点词），而不是上一条被动流自动查出来的。自动查出来的
///   卡本来就该被下一条流替换。
/// - [visible]：卡还在屏幕上。已藏起来的卡没有什么可保护，下一条流正常重开。
bool keepUserOwnedCardForPassiveStream({
  required bool passiveStream,
  required bool userOwnedCard,
  required bool visible,
}) =>
    passiveStream && userOwnedCard && visible;
