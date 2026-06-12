import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/reader_caret_router.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// The char-level reading cursor keeps A / Enter as configurable reader-scope
/// defaults via [ShortcutAction.readerLookupAtCursor]. The reader page still
/// handles them contextually (enter caret when inactive, activate when active),
/// and [ReaderCaretRouter] gates that caret behavior on the global focus
/// navigation switch. These tests pin the registry consequences: A belongs to
/// reader lookup, audiobook play/pause stays on L3, and bookmark stays on X.
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
      test(
          'controller A resolves to reader lookup, not audiobook, on $platform',
          () {
        final registry = registryFor(platform);
        expect(
          registry.resolveGamepad(GamepadButton.a, scope: ShortcutScope.reader),
          ShortcutAction.readerLookupAtCursor,
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

    test('Enter resolves to readerLookupAtCursor in the reader scope', () {
      final registry = registryFor(TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.enter,
          modifiers: const {},
          scope: ShortcutScope.reader,
        ),
        ShortcutAction.readerLookupAtCursor,
      );
    });

    test('focus navigation switch gates Enter / A caret entry', () {
      expect(
        ReaderCaretRouter.isEnterTriggerKeyboard(
          LogicalKeyboardKey.enter,
          focusNavEnabled: false,
        ),
        isFalse,
      );
      expect(
        ReaderCaretRouter.isEnterTriggerKeyboard(
          LogicalKeyboardKey.gameButtonA,
          focusNavEnabled: false,
        ),
        isFalse,
      );
      expect(
        ReaderCaretRouter.isEnterTriggerGamepad(
          GamepadButton.a,
          focusNavEnabled: false,
        ),
        isFalse,
      );
      expect(
        ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.enter),
        isTrue,
      );
      expect(
        ReaderCaretRouter.isEnterTriggerGamepad(GamepadButton.a),
        isTrue,
      );
    });
  });
}
