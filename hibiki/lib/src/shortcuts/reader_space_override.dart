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
ShortcutAction? resolveReaderArrowPageTurn({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool rtl,
  bool reverse = false,
  PhysicalKeyboardKey? physicalKey,
}) {
  if (modifiers.isNotEmpty) return null;
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

/// 桌面 Windows 阅读器「Ctrl+C 复制选中文字」止血兼容层（BUG-402）。
///
/// 根因：Windows 端 WebView 走 WebView2 合成模式，fork 的
/// `flutter_inappwebview_windows` 只转发鼠标、不转发键盘事件给 WebView2，
/// 所以浏览器原生 `copy` 永远触发不了——左键能选中文字（原生选区可建立），
/// 但 Ctrl+C / 右键复制都到不了 WebView2。移动端与 macOS 的 WebView 自带原生
/// copy，**不需要**也**不应该**被这个应用层快捷键覆盖（否则会双重处理）。
///
/// 本谓词只判定「这是不是 Windows 阅读器该接管的复制手势」：必须是
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
