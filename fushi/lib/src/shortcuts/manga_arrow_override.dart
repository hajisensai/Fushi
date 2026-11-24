import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'package:fushi/src/shortcuts/directional_page_turn.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/reader_space_override.dart'
    show resolveReaderSpaceOverride;
import 'package:fushi/src/shortcuts/shortcut_action.dart';

/// 漫画左右方向键的跨页方向校正。
///
/// 与阅读器的 `resolveReaderArrowPageTurn` 同构，理由也相同：注册表里存的是**页序
/// 语义**（forward = 下一页），而左右方向键的物理朝向该对应哪一侧，取决于书自己的
/// 跨页方向（日漫默认 rtl：下一页在**左**边，故左键 = 前进）。方向不能进注册表——
/// 注册表是全局的、每本书的排版却各不相同；若把 `ArrowLeft` 直接绑成 backward，
/// rtl 的书就会「翻反」。
///
/// 只在该键**仍是出厂绑定**（左 = 后退、右 = 前进）时才覆写（[boundAction] 判据）：
/// 用户若把左/右键改绑成相反的翻页方向、别的动作或解绑，就完全不介入，交回注册表的
/// 真实绑定。这样「改键」与「跟随书写方向」两个特性互不打架。判据与小说阅读器同一个
/// 原语 [resolveDirectionalPageTurn]（反馈 uz_2m0E_Eu：此前漫画只看「是不是翻页动作」，
/// 改绑成相反方向会被按跨页方向改回去，小说早在 BUG-3805 修掉了这一条）。
///
/// 上下键 / PageUp / PageDown / 空格**不参与**校正：它们是屏幕轴语义（下 = 往后
/// 读），与跨页方向无关，任何排版下都一致。
///
/// [reverse] = 漫画自己的「反转方向键翻页」开关（偏好 `manga_reverse_arrow_page_turn`，
/// 默认关；与小说的 `reverse_arrow_page_turn` 分开各一个，反馈 uz_2m0E_Eu ④）。只管
/// 键盘，与小说同一定义——手柄 D-pad 不受它影响。
ShortcutAction? resolveMangaArrowPageTurn({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool rtl,
  required ShortcutAction? boundAction,
  bool reverse = false,
}) {
  if (modifiers.isNotEmpty) return null;
  return resolveDirectionalPageTurn(
    side: directionalPageTurnSideForKey(key),
    boundAction: boundAction,
    forward: ShortcutAction.mangaPageForward,
    backward: ShortcutAction.mangaPageBackward,
    rtl: rtl,
    reverse: reverse,
  );
}

/// 有声漫画 / 漫画朗读在场时，裸空格与裸左右方向键默认由有声接管（反馈 WrLFAXNkSw，
/// 与有声书同一惯例）：
///
///  * 裸空格 → 播放 / 暂停。判据直接复用小说阅读器的 [resolveReaderSpaceOverride]
///    （有声在场 + 无修饰 + Space），两个阅读器不各写一套；
///  * 裸左 / 右 → 上一句 / 下一句。方向取 [resolveMangaArrowPageTurn] 已按跨页方向
///    校正好的页序（前进 = 下一句），所以只在该键仍是出厂翻页绑定时接管——用户改绑
///    / 解绑过就让路，与翻页方向校正同一判据。[pageAction] 传校正后的动作。
///
/// 不接管的情形：没有在场的有声（[audioActive] 假）、带修饰键、查词弹窗可见
/// （[dictionaryShown]：空格归弹窗、左右键是「关弹窗并翻页」）。PageUp / PageDown /
/// 滚轮 / 点按翻页一律不受影响，播放中照样能翻页（有声跟到新页页首）。返回 null
/// 表示不接管，交回原解析。
ShortcutAction? resolveMangaAudioKeyTakeover({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required ShortcutAction? pageAction,
  required bool audioActive,
  required bool dictionaryShown,
}) {
  if (!audioActive || dictionaryShown || modifiers.isNotEmpty) return null;
  if (resolveReaderSpaceOverride(
        key: key,
        modifiers: modifiers,
        hasActiveAudiobook: audioActive,
      ) !=
      null) {
    return ShortcutAction.mangaAudioPlayPause;
  }
  // 左右键切句与小说同一判据（反馈 uz_2m0E_Eu ①）。
  return resolveAudioArrowTakeover(
    key: key,
    modifiers: modifiers,
    pageAction: pageAction,
    pageForward: ShortcutAction.mangaPageForward,
    pageBackward: ShortcutAction.mangaPageBackward,
    nextLine: ShortcutAction.mangaAudioNextLine,
    previousLine: ShortcutAction.mangaAudioPreviousLine,
    audioActive: audioActive,
    dictionaryShown: dictionaryShown,
  );
}

/// 漫画手柄 D-pad 左/右的跨页方向校正——[resolveMangaArrowPageTurn] 的手柄同构。
///
/// 语义完全一致：注册表存**页序语义**，dpadLeft/dpadRight 的物理朝向按书的跨页
/// 方向（日漫默认 rtl）翻成 forward/backward；只在该按钮**仍是出厂绑定**时介入
/// （[boundAction] 判据），用户改绑/解绑后完全让路。RB/LB 等非方向按钮不参与
/// 校正——它们与 PageDown/空格同属页序语义，任何排版下都一致。
ShortcutAction? resolveMangaDpadPageTurn({
  required GamepadButton button,
  required bool rtl,
  required ShortcutAction? boundAction,
}) {
  return resolveDirectionalPageTurn(
    side: directionalPageTurnSideForGamepad(button),
    boundAction: boundAction,
    forward: ShortcutAction.mangaPageForward,
    backward: ShortcutAction.mangaPageBackward,
    rtl: rtl,
  );
}
