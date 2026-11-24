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
/// [reverse] 在阅读方向算出的结果上整体左右对调（「反转方向键翻页」开关，只管键盘；
/// 小说与漫画各有一个，偏好各自落盘——维护者 2026-11-23 拍板「两边分开」，反馈
/// uz_2m0E_Eu ④）；与 [rtl] 正交叠加：`leftIsForward = rtl ^ reverse`。
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

/// 有声在场时裸 ← / → 由「翻页」改作「上一句 / 下一句」——小说与漫画共用的判据
/// （反馈 uz_2m0E_Eu ①，维护者拍板「小说跟漫画走」；漫画此前由 BUG-5178 /
/// 反馈 WrLFAXNkSw 先做了）。
///
/// [pageAction] 必须是已经过 [resolveDirectionalPageTurn] 按阅读方向（与「反转方向键
/// 翻页」开关）校正好的**页序**动作：下一页 → [nextLine]、上一页 → [previousLine]。
/// 校正只在该键仍是出厂翻页绑定时发生，所以用户改绑 / 解绑过左右键就自然让路，
/// 不必在这里再判一次。
///
/// 不接管的情形（返回 null，交回原解析）：
///  * 没有在场的有声（[audioActive] 假）；
///  * 带修饰键（Ctrl+← → 本就是两边的切句键，Shift 等组合归各自绑定）；
///  * 不是裸 ← / →（PageUp / PageDown / ↑ / ↓ 仍然翻页，空格由各自的空格覆写管）；
///  * 查词弹窗可见（[dictionaryShown]）：← → 是「关弹窗并翻页」（反馈 uz_2m0E_Eu ③），
///    两个阅读器一致。
ShortcutAction? resolveAudioArrowTakeover({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required ShortcutAction? pageAction,
  required ShortcutAction pageForward,
  required ShortcutAction pageBackward,
  required ShortcutAction nextLine,
  required ShortcutAction previousLine,
  required bool audioActive,
  required bool dictionaryShown,
}) {
  if (!audioActive || dictionaryShown || modifiers.isNotEmpty) return null;
  if (directionalPageTurnSideForKey(key) == null) return null;
  if (pageAction == pageForward) return nextLine;
  if (pageAction == pageBackward) return previousLine;
  return null;
}
