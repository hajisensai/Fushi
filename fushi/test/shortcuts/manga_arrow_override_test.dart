import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/manga_arrow_override.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

void main() {
  group('resolveMangaArrowPageTurn', () {
    ShortcutAction? call(
      LogicalKeyboardKey key, {
      required bool rtl,
      ShortcutAction? bound = ShortcutAction.mangaPageForward,
      Set<ModifierKey> modifiers = const <ModifierKey>{},
    }) => resolveMangaArrowPageTurn(
      key: key,
      modifiers: modifiers,
      rtl: rtl,
      boundAction: bound,
    );

    test('rtl（日漫默认）：下一页在左 → 左键前进、右键后退', () {
      expect(
        call(LogicalKeyboardKey.arrowLeft, rtl: true),
        ShortcutAction.mangaPageForward,
      );
      expect(
        call(LogicalKeyboardKey.arrowRight, rtl: true),
        ShortcutAction.mangaPageBackward,
      );
    });

    test('ltr：下一页在右 → 右键前进、左键后退', () {
      expect(
        call(LogicalKeyboardKey.arrowRight, rtl: false),
        ShortcutAction.mangaPageForward,
      );
      expect(
        call(LogicalKeyboardKey.arrowLeft, rtl: false),
        ShortcutAction.mangaPageBackward,
      );
    });

    test('校正与「原本绑的是前进还是后退」无关，只看物理方向 + 排版方向', () {
      // 左右键互为镜像：无论注册表把某一侧绑成 forward 还是 backward，校正后的
      // 结果只由 rtl 决定。否则用户把左右键对调绑定后会出现「两个键都翻同一向」。
      expect(
        call(
          LogicalKeyboardKey.arrowLeft,
          rtl: true,
          bound: ShortcutAction.mangaPageBackward,
        ),
        ShortcutAction.mangaPageForward,
      );
      expect(
        call(
          LogicalKeyboardKey.arrowRight,
          rtl: true,
          bound: ShortcutAction.mangaPageForward,
        ),
        ShortcutAction.mangaPageBackward,
      );
    });

    test('该键已被改绑成非翻页动作 → 不覆写，交回注册表', () {
      expect(
        call(
          LogicalKeyboardKey.arrowLeft,
          rtl: true,
          bound: ShortcutAction.mangaDismissDict,
        ),
        isNull,
        reason: '尊重改键：只有仍绑定到翻页时方向校正才适用',
      );
      expect(
        call(LogicalKeyboardKey.arrowLeft, rtl: true, bound: null),
        isNull,
      );
    });

    test('带修饰键的组合不覆写', () {
      expect(
        call(
          LogicalKeyboardKey.arrowLeft,
          rtl: true,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
        ),
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

  group('resolveMangaDpadPageTurn（手柄 D-pad 的同构校正）', () {
    ShortcutAction? call(
      GamepadButton button, {
      required bool rtl,
      ShortcutAction? bound = ShortcutAction.mangaPageForward,
    }) =>
        resolveMangaDpadPageTurn(button: button, rtl: rtl, boundAction: bound);

    test('rtl（日漫默认）：dpad左前进、dpad右后退；ltr 相反', () {
      expect(
        call(GamepadButton.dpadLeft, rtl: true),
        ShortcutAction.mangaPageForward,
      );
      expect(
        call(GamepadButton.dpadRight, rtl: true),
        ShortcutAction.mangaPageBackward,
      );
      expect(
        call(GamepadButton.dpadRight, rtl: false),
        ShortcutAction.mangaPageForward,
      );
      expect(
        call(GamepadButton.dpadLeft, rtl: false),
        ShortcutAction.mangaPageBackward,
      );
    });

    test('校正只看物理方向 + 排版方向，与原绑定的前进/后退无关（键盘同款不变式）', () {
      expect(
        call(
          GamepadButton.dpadLeft,
          rtl: true,
          bound: ShortcutAction.mangaPageBackward,
        ),
        ShortcutAction.mangaPageForward,
      );
    });

    test('已改绑成非翻页动作 / 未绑定 → 不覆写，交回注册表', () {
      expect(
        call(
          GamepadButton.dpadLeft,
          rtl: true,
          bound: ShortcutAction.mangaDismissDict,
        ),
        isNull,
      );
      expect(call(GamepadButton.dpadLeft, rtl: true, bound: null), isNull);
    });

    test('非 D-pad 左右按钮不参与校正（RB/LB 是页序语义，任何排版下一致）', () {
      for (final GamepadButton button in <GamepadButton>[
        GamepadButton.rb,
        GamepadButton.lb,
        GamepadButton.dpadUp,
        GamepadButton.dpadDown,
        GamepadButton.a,
        GamepadButton.b,
      ]) {
        expect(
          call(button, rtl: true),
          isNull,
          reason: '${button.label} 不该被方向校正',
        );
      }
    });
  });

  // 反馈 WrLFAXNkSw：有声在场时裸空格 / 左右键默认由有声接管（与有声书同一惯例）。
  group('resolveMangaAudioKeyTakeover', () {
    ShortcutAction? call(
      LogicalKeyboardKey key, {
      ShortcutAction? page = ShortcutAction.mangaPageForward,
      bool audio = true,
      bool dict = false,
      Set<ModifierKey> modifiers = const <ModifierKey>{},
    }) => resolveMangaAudioKeyTakeover(
      key: key,
      modifiers: modifiers,
      pageAction: page,
      audioActive: audio,
      dictionaryShown: dict,
    );

    test('有声在场：空格 = 播放暂停，左右键按校正后的页序 = 下一句 / 上一句', () {
      expect(
        call(LogicalKeyboardKey.space),
        ShortcutAction.mangaAudioPlayPause,
      );
      // rtl 下左键已被校正成前进 → 下一句；右键后退 → 上一句。
      expect(
        call(
          LogicalKeyboardKey.arrowLeft,
          page: resolveMangaArrowPageTurn(
            key: LogicalKeyboardKey.arrowLeft,
            modifiers: const <ModifierKey>{},
            rtl: true,
            boundAction: ShortcutAction.mangaPageBackward,
          ),
        ),
        ShortcutAction.mangaAudioNextLine,
      );
      expect(
        call(
          LogicalKeyboardKey.arrowRight,
          page: ShortcutAction.mangaPageBackward,
        ),
        ShortcutAction.mangaAudioPreviousLine,
      );
    });

    test('没有有声 / 弹窗可见 / 带修饰键：不接管', () {
      expect(call(LogicalKeyboardKey.space, audio: false), isNull);
      expect(call(LogicalKeyboardKey.arrowLeft, audio: false), isNull);
      expect(call(LogicalKeyboardKey.space, dict: true), isNull);
      expect(call(LogicalKeyboardKey.arrowRight, dict: true), isNull);
      expect(
        call(
          LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
        ),
        isNull,
      );
      expect(
        call(
          LogicalKeyboardKey.space,
          modifiers: const <ModifierKey>{ModifierKey.shift},
        ),
        isNull,
      );
    });

    test('左右键改绑成别的动作时让路；PageDown 等其它翻页键不接管', () {
      expect(
        call(
          LogicalKeyboardKey.arrowLeft,
          page: ShortcutAction.mangaToggleBookmark,
        ),
        isNull,
      );
      expect(call(LogicalKeyboardKey.arrowLeft, page: null), isNull);
      expect(call(LogicalKeyboardKey.pageDown), isNull);
      expect(call(LogicalKeyboardKey.arrowDown), isNull);
    });
  });
}
