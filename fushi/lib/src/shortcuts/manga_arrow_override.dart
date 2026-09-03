import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

/// 漫画左右方向键的跨页方向校正。
///
/// 与阅读器的 `resolveReaderArrowPageTurn` 同构，理由也相同：注册表里存的是**页序
/// 语义**（forward = 下一页），而左右方向键的物理朝向该对应哪一侧，取决于书自己的
/// 跨页方向（日漫默认 rtl：下一页在**左**边，故左键 = 前进）。方向不能进注册表——
/// 注册表是全局的、每本书的排版却各不相同；若把 `ArrowLeft` 直接绑成 backward，
/// rtl 的书就会「翻反」。
///
/// 只在该键**当前仍绑定到翻页动作**时才覆写（[boundAction] 判据）：用户若把左/右
/// 键改绑成别的动作或解绑，就完全不介入，交回注册表的真实绑定。这样「改键」与
/// 「跟随书写方向」两个特性互不打架。
///
/// 上下键 / PageUp / PageDown / 空格**不参与**校正：它们是屏幕轴语义（下 = 往后
/// 读），与跨页方向无关，任何排版下都一致。
ShortcutAction? resolveMangaArrowPageTurn({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool rtl,
  required ShortcutAction? boundAction,
}) {
  if (modifiers.isNotEmpty) return null;
  if (boundAction != ShortcutAction.mangaPageForward &&
      boundAction != ShortcutAction.mangaPageBackward) {
    return null;
  }
  final bool isLeft = key == LogicalKeyboardKey.arrowLeft;
  final bool isRight = key == LogicalKeyboardKey.arrowRight;
  if (!isLeft && !isRight) return null;
  return _directionalPageTurn(isLeft: isLeft, rtl: rtl);
}

/// 漫画手柄 D-pad 左/右的跨页方向校正——[resolveMangaArrowPageTurn] 的手柄同构。
///
/// 语义完全一致：注册表存**页序语义**，dpadLeft/dpadRight 的物理朝向按书的跨页
/// 方向（日漫默认 rtl）翻成 forward/backward；只在该按钮**当前仍绑定到翻页动作**时
/// 介入（[boundAction] 判据），用户改绑/解绑后完全让路。RB/LB 等非方向按钮不参与
/// 校正——它们与 PageDown/空格同属页序语义，任何排版下都一致。
ShortcutAction? resolveMangaDpadPageTurn({
  required GamepadButton button,
  required bool rtl,
  required ShortcutAction? boundAction,
}) {
  if (boundAction != ShortcutAction.mangaPageForward &&
      boundAction != ShortcutAction.mangaPageBackward) {
    return null;
  }
  final bool isLeft = button == GamepadButton.dpadLeft;
  final bool isRight = button == GamepadButton.dpadRight;
  if (!isLeft && !isRight) return null;
  return _directionalPageTurn(isLeft: isLeft, rtl: rtl);
}

/// 物理左/右 → 页序动作。rtl（日漫默认）：下一页在左 → 左 = 前进。
ShortcutAction _directionalPageTurn({required bool isLeft, required bool rtl}) {
  final bool leftIsForward = rtl;
  if (isLeft) {
    return leftIsForward
        ? ShortcutAction.mangaPageForward
        : ShortcutAction.mangaPageBackward;
  }
  return leftIsForward
      ? ShortcutAction.mangaPageBackward
      : ShortcutAction.mangaPageForward;
}
