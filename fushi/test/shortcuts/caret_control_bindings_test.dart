import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/reader_caret_router.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// The char-level reading cursor keeps Enter as a configurable reader-scope
/// default via [ShortcutAction.readerLookupAtCursor]. The reader page still
/// handles it contextually (enter caret when inactive, activate when active),
/// and [ReaderCaretRouter] gates that caret behavior on the global focus
/// navigation switch. The gamepad has no caret entry since the 2026-11-22
/// gamepad lookup unification (the controller lookup mode is the gamepad's only
/// lookup), so A no longer resolves to reader lookup. These tests pin the
/// registry consequences: A is not reader lookup, audiobook play/pause stays on
/// L3, and bookmark stays on X.
void main() {
  group('caret control bindings', () {
    FushiShortcutRegistry registryFor(TargetPlatform platform) =>
        FushiShortcutRegistry()..loadDefaults(platform);

    for (final platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      test('controller A resolves to neither reader lookup nor audiobook on '
          '$platform', () {
        final registry = registryFor(platform);
        expect(
          registry.resolveGamepad(GamepadButton.a, scope: ShortcutScope.reader),
          isNull,
        );
        expect(
          registry.resolveGamepad(
            GamepadButton.a,
            scope: ShortcutScope.audiobook,
          ),
          isNull,
        );
      });

      test('audiobook play/pause is on L3, not A, on $platform', () {
        final registry = registryFor(platform);
        expect(
          registry.resolveGamepad(
            GamepadButton.thumbLeft,
            scope: ShortcutScope.audiobook,
          ),
          ShortcutAction.audiobookPlayPause,
        );
      });

      // TODO-700 T2：X 从书签改给「下一句」(audiobookNextSentence)，B 给「上一句」。
      // 书签手柄默认让位（键盘 Ctrl+D 仍在）。X/B 落 audiobook scope，不再 reader scope。
      test('controller X = next sentence, B = prev sentence on $platform', () {
        final registry = registryFor(platform);
        expect(
          registry.resolveGamepad(
            GamepadButton.x,
            scope: ShortcutScope.audiobook,
          ),
          ShortcutAction.audiobookNextSentence,
        );
        expect(
          registry.resolveGamepad(
            GamepadButton.b,
            scope: ShortcutScope.audiobook,
          ),
          ShortcutAction.audiobookPrevSentence,
        );
        expect(
          registry.resolveGamepad(GamepadButton.x, scope: ShortcutScope.reader),
          isNull,
          reason: '书签手柄 X 已让位',
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
        ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.enter),
        isTrue,
      );
    });
  });
}
