import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// The char-level reading cursor is entered with A / Enter and left with B / Esc
/// — handled contextually on the reader page (depends on cursor state + whether
/// the bottom chrome has focus), NOT via a registry action. These tests pin the
/// surrounding registry consequences: A is freed of any reader/audiobook binding
/// (so the page-level interception owns it), play/pause relocates to L3, and the
/// bookmark stays on X.
void main() {
  group('caret control bindings', () {
    HibikiShortcutRegistry registryFor(TargetPlatform platform) =>
        HibikiShortcutRegistry()..loadDefaults(platform);

    for (final platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      test('controller A has no reader/audiobook registry binding on $platform',
          () {
        final registry = registryFor(platform);
        expect(
          registry.resolveGamepad(GamepadButton.a, scope: ShortcutScope.reader),
          isNull,
        );
        expect(
          registry.resolveGamepad(GamepadButton.a,
              scope: ShortcutScope.audiobook),
          isNull,
        );
      });

      test('audiobook play/pause is on L3, not A, on $platform', () {
        final registry = registryFor(platform);
        expect(
          registry.resolveGamepad(GamepadButton.thumbLeft,
              scope: ShortcutScope.audiobook),
          ShortcutAction.audiobookPlayPause,
        );
      });

      test('bookmark stays on controller X on $platform', () {
        final registry = registryFor(platform);
        expect(
          registry.resolveGamepad(GamepadButton.x, scope: ShortcutScope.reader),
          ShortcutAction.readerToggleBookmark,
        );
      });
    }

    test('Enter is NOT a registry action in the reader scope (cursor entry is '
        'page-level, contextual on focus + cursor state)', () {
      final registry = registryFor(TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.enter,
          modifiers: const {},
          scope: ShortcutScope.reader,
        ),
        isNull,
      );
    });
  });
}
