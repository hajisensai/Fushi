import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_gamepad_immersive.dart';

/// TODO-728 (1) pure ownership guard for the gamepad auto-immersive chrome rule.
void main() {
  group('resolveGamepadImmersive', () {
    test('controller present + chrome shown -> hide + claim ownership', () {
      final GamepadImmersiveState s = resolveGamepadImmersive(
        present: true,
        showChrome: true,
        hiddenByGamepad: false,
      );
      expect(s.showChrome, isFalse);
      expect(s.hiddenByGamepad, isTrue);
    });

    test('controller present + chrome already hidden -> no claim, no change',
        () {
      final GamepadImmersiveState s = resolveGamepadImmersive(
        present: true,
        showChrome: false,
        hiddenByGamepad: false,
      );
      expect(s.showChrome, isFalse);
      // Must NOT claim ownership of a chrome the user hid.
      expect(s.hiddenByGamepad, isFalse);
    });

    test('controller gone + gamepad-owned hide -> restore + clear ownership',
        () {
      final GamepadImmersiveState s = resolveGamepadImmersive(
        present: false,
        showChrome: false,
        hiddenByGamepad: true,
      );
      expect(s.showChrome, isTrue);
      expect(s.hiddenByGamepad, isFalse);
    });

    test(
        'controller gone + NOT gamepad-owned (user toggled in between) -> '
        'chrome unchanged, ownership stays cleared', () {
      // Simulates: gamepad hid chrome -> user manually toggled (which clears the
      // flag) -> controller leaves. The leave must NOT restore the chrome.
      final GamepadImmersiveState s = resolveGamepadImmersive(
        present: false,
        showChrome: false,
        hiddenByGamepad: false,
      );
      expect(s.showChrome, isFalse,
          reason: 'controller leaving must not override the user');
      expect(s.hiddenByGamepad, isFalse);
    });

    test('controller gone while chrome shown + not owned -> no-op', () {
      final GamepadImmersiveState s = resolveGamepadImmersive(
        present: false,
        showChrome: true,
        hiddenByGamepad: false,
      );
      expect(s.showChrome, isTrue);
      expect(s.hiddenByGamepad, isFalse);
    });
  });
}
