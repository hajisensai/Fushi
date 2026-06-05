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
}
