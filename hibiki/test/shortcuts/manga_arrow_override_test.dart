import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/manga_arrow_override.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

void main() {
  group('resolveMangaArrowPageTurn', () {
    ShortcutAction? call(
      LogicalKeyboardKey key, {
      required bool rtl,
      ShortcutAction? bound = ShortcutAction.mangaPageForward,
      Set<ModifierKey> modifiers = const <ModifierKey>{},
    }) =>
        resolveMangaArrowPageTurn(
          key: key,
          modifiers: modifiers,
          rtl: rtl,
          boundAction: bound,
        );

    test('rtl（日漫默认）：下一页在左 → 左键前进、右键后退', () {
      expect(call(LogicalKeyboardKey.arrowLeft, rtl: true),
          ShortcutAction.mangaPageForward);
      expect(call(LogicalKeyboardKey.arrowRight, rtl: true),
          ShortcutAction.mangaPageBackward);
    });

    test('ltr：下一页在右 → 右键前进、左键后退', () {
      expect(call(LogicalKeyboardKey.arrowRight, rtl: false),
          ShortcutAction.mangaPageForward);
      expect(call(LogicalKeyboardKey.arrowLeft, rtl: false),
          ShortcutAction.mangaPageBackward);
    });

    test('校正与「原本绑的是前进还是后退」无关，只看物理方向 + 排版方向', () {
      // 左右键互为镜像：无论注册表把某一侧绑成 forward 还是 backward，校正后的
      // 结果只由 rtl 决定。否则用户把左右键对调绑定后会出现「两个键都翻同一向」。
      expect(
        call(LogicalKeyboardKey.arrowLeft,
            rtl: true, bound: ShortcutAction.mangaPageBackward),
        ShortcutAction.mangaPageForward,
      );
      expect(
        call(LogicalKeyboardKey.arrowRight,
            rtl: true, bound: ShortcutAction.mangaPageForward),
        ShortcutAction.mangaPageBackward,
      );
    });

    test('该键已被改绑成非翻页动作 → 不覆写，交回注册表', () {
      expect(
        call(LogicalKeyboardKey.arrowLeft,
            rtl: true, bound: ShortcutAction.mangaDismissDict),
        isNull,
        reason: '尊重改键：只有仍绑定到翻页时方向校正才适用',
      );
      expect(
          call(LogicalKeyboardKey.arrowLeft, rtl: true, bound: null), isNull);
    });

    test('带修饰键的组合不覆写', () {
      expect(
        call(LogicalKeyboardKey.arrowLeft,
            rtl: true, modifiers: const <ModifierKey>{ModifierKey.ctrl}),
        isNull,
      );
    });

    test('非左右键不参与校正（上下 / PageUp / 空格是屏幕轴语义）', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.space,
      ]) {
        expect(call(key, rtl: true), isNull, reason: '$key 不该被方向校正');
      }
    });
  });
}
