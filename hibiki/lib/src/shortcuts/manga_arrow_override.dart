import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

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
  // rtl（日漫默认）：下一页在左 → 左键前进。ltr：下一页在右 → 右键前进。
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
