import 'package:flutter/services.dart' show LogicalKeyboardKey;

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
ShortcutAction? resolveReaderSpaceOverride({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool hasActiveAudiobook,
}) {
  if (key != LogicalKeyboardKey.space) return null;
  if (modifiers.isNotEmpty) return null;
  if (!hasActiveAudiobook) return null;
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
ShortcutAction? resolveReaderArrowPageTurn({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool rtl,
  bool reverse = false,
}) {
  if (modifiers.isNotEmpty) return null;
  final bool leftIsForward = rtl ^ reverse;
  if (key == LogicalKeyboardKey.arrowLeft) {
    return leftIsForward
        ? ShortcutAction.readerPageForward
        : ShortcutAction.readerPageBackward;
  }
  if (key == LogicalKeyboardKey.arrowRight) {
    return leftIsForward
        ? ShortcutAction.readerPageBackward
        : ShortcutAction.readerPageForward;
  }
  return null;
}
