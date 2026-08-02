import 'package:flutter/services.dart'
    show LogicalKeyboardKey, PhysicalKeyboardKey;

import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

/// 有声书激活时，无修饰 Space 改作播放/暂停（媒体播放器惯例）。
///
/// 设计：阅读器键盘解析里 reader scope 先于 audiobook scope，默认绑定中
/// Space=翻页、Ctrl+Space=播放/暂停，导致有声书场景按 Space 永远翻页。
/// 本函数仅在「有声书已激活 + 无任何修饰键 + 是 Space」时返回
/// [ShortcutAction.audiobookPlayPause] 覆写翻页；其余一律返回 null 表示
/// 不覆写，交回默认解析（翻页仍可用方向键/PageDown；Shift+Space 仍后退翻页；
/// Ctrl+Space 保留原义）。
///
/// TODO-847：Windows 微软 IME 激活时 [key] 会被引擎改写成 [LogicalKeyboardKey.process]，
/// 裸 Space 判定失效（有声书场景按 Space 不再播放/暂停）。当 `key == process &&
/// physicalKey == PhysicalKeyboardKey.space` 时按物理键还原 Space 语义；文本框
/// composing 时调用方传 [physicalKey] null 关闭回退。仅对 US-QWERTY 物理布局而言
/// Space 物理键稳定（Space 在所有常见布局上物理位一致，故此键实际不受布局影响）。
ShortcutAction? resolveReaderSpaceOverride({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool hasActiveAudiobook,
  PhysicalKeyboardKey? physicalKey,
}) {
  if (modifiers.isNotEmpty) return null;
  if (!hasActiveAudiobook) return null;
  final bool isSpace = key == LogicalKeyboardKey.space ||
      (key == LogicalKeyboardKey.process &&
          physicalKey == PhysicalKeyboardKey.space);
  if (!isSpace) return null;
  return ShortcutAction.audiobookPlayPause;
}

/// 键盘裸左右键翻页必须跟随阅读方向（BUG-098）：
/// - 竖排 RTL（`vertical-rl`，日文默认）：从右往左读，「下一页」在左 → 左箭头前进、
///   右箭头后退。
/// - 横排 LTR（`horizontal-tb`）：从左往右读，「下一页」在右 → 右箭头前进、
///   左箭头后退。
///
/// 默认键盘绑定把「右箭头=前进」写死，对 RTL 书方向恰好相反。本函数在注册表解析前
/// 介入，仅处理**键盘**「无修饰的裸左/右箭头」；其它键（上/下箭头、PageUp/PageDown、
/// Space、字母键，以及 Ctrl+方向键的有声书句子导航）一律返回 null，交回默认解析不受影响。
/// D-pad / gamepad / joystick 事件必须先走 gamepad registry，不进入这个 helper。
///
/// [reverse]（TODO-120 用户开关 `reverse_arrow_page_turn`，默认 false）只对**最终
/// 方向**整体取反：先按阅读方向（[rtl]）算出前进/后退，再在开关打开时把前进/后退对调。
/// 这样无论 LTR 还是 RTL，开关都只把键盘左右键当前行为整体反过来（左↔右互换），
/// 与 RTL 自动判定正交叠加，不影响手柄映射、字母快捷键或滑动手势。
///
/// TODO-847：IME 改写 [key] 成 [LogicalKeyboardKey.process] 时裸左右键判定失效，
/// 导致 RTL 书翻页方向反转（落回注册表的 Right=前进 写死映射）。当
/// `key == process` 时用 [physicalKey] 还原 arrowLeft/arrowRight 语义；文本框
/// composing 时调用方传 null 关闭回退。方向键物理位在常见布局一致，回退稳定。
///
/// TODO-992：本覆写只为「翻页绑定」做阅读方向校正，**必须尊重用户改键**。调用方传入
/// 该裸键当前在阅读器 co-active 组（reader + audiobook scope）解析出的 [boundAction]：
/// - 仍是翻页动作（[ShortcutAction.readerPageForward]/[ShortcutAction.readerPageBackward]）
///   → 按阅读方向重定向，保持 BUG-098/099/TODO-120 既有行为。
/// - 被用户改绑成别的动作（如有声书上/下句）或显式解绑（null）→ 返回 null 让出，
///   交回注册表解析用户的真实绑定（修复「连续滚动模式下左右键仍只翻页不动有声书」，
///   分页与连续两模式都走这条统一解析，故两模式一并修复）。
/// 默认绑定下裸 Left/Right 仍解析为翻页，故默认用户行为不变（Never break userspace）。
ShortcutAction? resolveReaderArrowPageTurn({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool rtl,
  required ShortcutAction? boundAction,
  bool reverse = false,
  PhysicalKeyboardKey? physicalKey,
}) {
  if (modifiers.isNotEmpty) return null;
  // 用户已把裸左/右键改绑成非翻页动作（或解绑）→ 不覆写，交回注册表解析真实绑定。
  // 只有当该键仍绑定到翻页时，阅读方向校正才适用。
  if (boundAction != ShortcutAction.readerPageForward &&
      boundAction != ShortcutAction.readerPageBackward) {
    return null;
  }
  final bool leftIsForward = rtl ^ reverse;
  final bool isLeft = key == LogicalKeyboardKey.arrowLeft ||
      (key == LogicalKeyboardKey.process &&
          physicalKey == PhysicalKeyboardKey.arrowLeft);
  final bool isRight = key == LogicalKeyboardKey.arrowRight ||
      (key == LogicalKeyboardKey.process &&
          physicalKey == PhysicalKeyboardKey.arrowRight);
  if (isLeft) {
    return leftIsForward
        ? ShortcutAction.readerPageForward
        : ShortcutAction.readerPageBackward;
  }
  if (isRight) {
    return leftIsForward
        ? ShortcutAction.readerPageBackward
        : ShortcutAction.readerPageForward;
  }
  return null;
}

/// 触摸 / 鼠标滑动翻页方向必须跟随书写方向（横排 LTR 与竖排 vertical-rl 相反），
/// 与键盘方向键 [resolveReaderArrowPageTurn] 的 `leftIsForward = rtl ^ reverse` 同构。
///
/// 返回「向左滑（`onSwipe('left')`，手指 dx<0）是否 = 前进」。
/// - [invert] = 用户 `invertSwipeDirection` 开关（默认 true）。
/// - [rtl] = 竖排 vertical-rl（日文默认，`_isRtlReading`）。
///
/// `invert ^ rtl` 的四象限：
/// - 竖排默认(rtl=T, invert=T) → false：右滑前进（**与历史行为一致**，不破坏既有手感）。
/// - 横排默认(rtl=F, invert=T) → true：左滑前进（LTR 下一页在右，推内容向左露出=前进）。
///
/// 此前滑动路径只用 [invert] 不看书写方向，横排与竖排共用同一套映射（横排方向反了）；
/// 键盘路径早已翻转，滑动漏了，本谓词补齐。
bool swipeLeftIsForward({required bool invert, required bool rtl}) =>
    invert ^ rtl;

/// 桌面 Windows 阅读器「Ctrl+C 复制选中文字」止血兼容层（BUG-402）。
///
/// 根因：Windows 端 WebView 走 WebView2 合成模式，fork 的
/// `flutter_inappwebview_windows` 只转发鼠标、不转发键盘事件给 WebView2，
/// 所以浏览器原生 `copy` 永远触发不了——左键能选中文字（原生选区可建立），
/// 但 Ctrl+C / 右键复制都到不了 WebView2。移动端与 macOS 的 WebView 自带原生
/// copy，**不需要**也**不应该**被这个应用层快捷键覆盖（否则会双重处理）。
///
/// BUG-1451：查词弹窗（[DictionaryPopupWebView]）与阅读器正文**共用**本谓词——两者
/// 断在同一个平台事实上（fork 不转发键盘），判据必须同源，否则改一处另一处会漂开。
/// 名字保留 `reader` 前缀只为不破坏既有测试/守卫引用，语义是「桌面该接管的复制手势」。
///
/// 本谓词只判定「这是不是 Windows 该接管的复制手势」：必须是
/// Windows + 仅 Ctrl 修饰（无 Shift/Alt/Meta，避开 Ctrl+Shift+C 等其它组合）
/// + 键是 C。命中后由调用方取 `window.getSelection()`（浏览器原生选区，**不是**
/// `window.hoshiSelection` 查词选区）的文本写入系统剪贴板。其余一律返回 false，
/// 交回默认处理，不吞键、不改任何现有行为。
bool readerShouldHandleDesktopCopy({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool isWindows,
}) {
  if (!isWindows) return false;
  if (key != LogicalKeyboardKey.keyC) return false;
  return modifiers.length == 1 && modifiers.contains(ModifierKey.ctrl);
}

/// TODO-1370：长按方向键连续切句。判断一个已解析出的阅读器/有声书快捷动作是否应随
/// OS 键盘自动重复（[KeyRepeatEvent]）连续触发。
///
/// 根因：阅读器 `_handleKeyEvent` 在解析快捷键前有 `event is! KeyDownEvent` 闸门，
/// 把长按产生的 KeyRepeat 事件全部丢弃（字符光标除外），所以按住 Ctrl+←/→（或用户
/// 改绑成裸 ←/→）的「上一句/下一句」只在按下瞬间触发一次，无法连续切句——而视频
/// 播放器经 `SingleActivator(includeRepeats: true)`、手柄 D-pad 经 `GamepadFrameProcessor`
/// 自动重复，两者都连续。本谓词让阅读器键盘路径与它们对齐。
///
/// 只放行「移动 / 前进后退」类动作：翻页（[ShortcutAction.readerPageForward] /
/// [ShortcutAction.readerPageBackward]）与有声书上一句/下一句
/// （[ShortcutAction.audiobookPrevSentence] / [ShortcutAction.audiobookNextSentence]）。
/// 离散动作（查词 / 书签 / 关词典 / 打开菜单 / 播放暂停）必须一次一按，绝不随长按连发
/// （否则按住会连续查词 / 反复开关播放），故默认一律返回 false；新增 action 也默认不
/// 可重复，需显式加入白名单才连发。
bool isRepeatableReaderKeyboardShortcut(ShortcutAction action) {
  switch (action) {
    case ShortcutAction.readerPageForward:
    case ShortcutAction.readerPageBackward:
    case ShortcutAction.audiobookNextSentence:
    case ShortcutAction.audiobookPrevSentence:
      return true;
    default:
      return false;
  }
}
