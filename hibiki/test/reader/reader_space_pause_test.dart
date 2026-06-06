import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/reader_space_override.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

void main() {
  group('resolveReaderSpaceOverride', () {
    test('有声书激活 + 无修饰 Space → 播放/暂停', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.space,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: true,
        ),
        ShortcutAction.audiobookPlayPause,
      );
    });

    test('无有声书 + 无修饰 Space → 不覆写(走默认翻页)', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.space,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: false,
        ),
        isNull,
      );
    });

    test('有声书激活 + Shift+Space → 不覆写(仍后退翻页)', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.space,
          modifiers: const <ModifierKey>{ModifierKey.shift},
          hasActiveAudiobook: true,
        ),
        isNull,
      );
    });

    test('有声书激活 + Ctrl+Space → 不覆写(保留 Ctrl+Space 原义)', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.space,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
          hasActiveAudiobook: true,
        ),
        isNull,
      );
    });

    test('非 Space 键 → 不覆写', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: true,
        ),
        isNull,
      );
    });
  });

  group('resolveReaderArrowPageTurn (BUG-099 翻页方向键跟随阅读方向)', () {
    test('LTR(横排) 右箭头 → 前进 / 左箭头 → 后退', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: false,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: false,
        ),
        ShortcutAction.readerPageBackward,
      );
    });

    test('RTL(竖排) 左箭头 → 前进 / 右箭头 → 后退（下一页在左）', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: true,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: true,
        ),
        ShortcutAction.readerPageBackward,
      );
    });

    test('带修饰键(Ctrl+方向键=有声书句子导航) → 不覆写', () {
      for (final bool rtl in <bool>[true, false]) {
        expect(
          resolveReaderArrowPageTurn(
            key: LogicalKeyboardKey.arrowRight,
            modifiers: const <ModifierKey>{ModifierKey.ctrl},
            rtl: rtl,
          ),
          isNull,
        );
        expect(
          resolveReaderArrowPageTurn(
            key: LogicalKeyboardKey.arrowLeft,
            modifiers: const <ModifierKey>{ModifierKey.ctrl},
            rtl: rtl,
          ),
          isNull,
        );
      }
    });

    test('上/下箭头与其它键 → 不覆写(交回默认解析)', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.space,
      ]) {
        expect(
          resolveReaderArrowPageTurn(
            key: key,
            modifiers: const <ModifierKey>{},
            rtl: true,
          ),
          isNull,
        );
      }
    });
  });
}
