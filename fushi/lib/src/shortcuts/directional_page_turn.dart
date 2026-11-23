import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

/// 物理左 / 右翻页键（键盘 ← → 与手柄 D-pad 左 / 右）。
enum DirectionalPageTurnSide { left, right }

/// 键盘裸 ← / → → 物理侧；其它键返回 null。修饰键由调用方先行排除。
DirectionalPageTurnSide? directionalPageTurnSideForKey(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowLeft) return DirectionalPageTurnSide.left;
  if (key == LogicalKeyboardKey.arrowRight) {
    return DirectionalPageTurnSide.right;
  }
  return null;
}

/// 手柄 D-pad 左 / 右 → 物理侧；其它按钮（RB / LB / 上下 / 面键）返回 null。
DirectionalPageTurnSide? directionalPageTurnSideForGamepad(
  GamepadButton button,
) {
  if (button == GamepadButton.dpadLeft) return DirectionalPageTurnSide.left;
  if (button == GamepadButton.dpadRight) return DirectionalPageTurnSide.right;
  return null;
}

/// 小说阅读器与漫画阅读器共用的「左右翻页跟随阅读方向」原语（反馈 uz_2m0E_Eu）。
///
/// 注册表里存的是**页序语义**（forward = 下一页），出厂绑定是「左 = 后退、右 = 前进」
/// （`shortcut_defaults.dart`，两个阅读器、键盘与 D-pad 都一样）。物理左右该对应哪一
/// 侧取决于这本书的阅读方向：从右往左读（竖排 vertical-rl 的小说、rtl 跨页的日漫）时
/// 下一页在**左**边，左 = 前进；从左往右读时右 = 前进。
///
/// 只接管**出厂物理方向绑定**：[boundAction] 必须正好是该侧的出厂动作（左 →
/// [backward]、右 → [forward]）。用户把该键改绑成相反的翻页方向、别的动作或解绑，都
/// 是明确意图，返回 null 交回注册表解析真实绑定（BUG-3805 / 反馈 aiRZmYl5zS）。
///
/// [reverse] 在阅读方向算出的结果上整体左右对调（小说的「反转方向键翻页」开关，只管
/// 键盘）；与 [rtl] 正交叠加：`leftIsForward = rtl ^ reverse`。
///
/// 此前两个阅读器各写一份：小说只接管出厂绑定、漫画只要是翻页动作就一律按跨页方向
/// 改写（用户改绑的相反方向会被改回去），小说的 D-pad 则完全不看阅读方向——同一个
/// 键在两种书里翻的方向判据不同。现在键盘与手柄、小说与漫画都只走这一个函数。
ShortcutAction? resolveDirectionalPageTurn({
  required DirectionalPageTurnSide? side,
  required ShortcutAction? boundAction,
  required ShortcutAction forward,
  required ShortcutAction backward,
  required bool rtl,
  bool reverse = false,
}) {
  if (side == null) return null;
  final bool isLeft = side == DirectionalPageTurnSide.left;
  final ShortcutAction factoryBinding = isLeft ? backward : forward;
  if (boundAction != factoryBinding) return null;
  final bool leftIsForward = rtl ^ reverse;
  return isLeft == leftIsForward ? forward : backward;
}
