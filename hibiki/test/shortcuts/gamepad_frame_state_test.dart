import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart' as gp;

import 'package:hibiki/src/shortcuts/gamepad_service.dart';

/// Verifies the pure folding from the `gamepads` plugin's normalized
/// buttons/axes into the internal [GamepadFrameBits] frame. This is the
/// platform-coupling layer that runs on Windows/iOS/macOS/Linux (which can't be
/// exercised on the Windows test host), so it is unit-tested directly.
void main() {
  late GamepadFrameState state;

  setUp(() => state = GamepadFrameState());

  group('button folding (bitmask set/clear on press/release)', () {
    test('press sets the bit, release clears it', () {
      state.applyButton(gp.GamepadButton.a, 1.0);
      expect(state.buttons & GamepadFrameBits.a, isNonZero);
      state.applyButton(gp.GamepadButton.a, 0.0);
      expect(state.buttons & GamepadFrameBits.a, 0);
    });

    test('multiple held buttons OR together; releasing one keeps the others',
        () {
      state.applyButton(gp.GamepadButton.a, 1.0);
      state.applyButton(gp.GamepadButton.b, 1.0);
      expect(state.buttons & GamepadFrameBits.a, isNonZero);
      expect(state.buttons & GamepadFrameBits.b, isNonZero);
      state.applyButton(gp.GamepadButton.a, 0.0);
      expect(state.buttons & GamepadFrameBits.a, 0);
      expect(state.buttons & GamepadFrameBits.b, isNonZero);
    });

    test('the cross-platform button names map to the right frame bits', () {
      final Map<gp.GamepadButton, int> expected = <gp.GamepadButton, int>{
        gp.GamepadButton.x: GamepadFrameBits.x,
        gp.GamepadButton.y: GamepadFrameBits.y,
        gp.GamepadButton.leftBumper: GamepadFrameBits.leftShoulder,
        gp.GamepadButton.rightBumper: GamepadFrameBits.rightShoulder,
        gp.GamepadButton.back: GamepadFrameBits.back,
        gp.GamepadButton.start: GamepadFrameBits.start,
        gp.GamepadButton.leftStick: GamepadFrameBits.leftThumb,
        gp.GamepadButton.rightStick: GamepadFrameBits.rightThumb,
        gp.GamepadButton.dpadUp: GamepadFrameBits.dpadUp,
        gp.GamepadButton.dpadDown: GamepadFrameBits.dpadDown,
        gp.GamepadButton.dpadLeft: GamepadFrameBits.dpadLeft,
        gp.GamepadButton.dpadRight: GamepadFrameBits.dpadRight,
      };
      expected.forEach((gp.GamepadButton button, int bit) {
        final GamepadFrameState s = GamepadFrameState();
        s.applyButton(button, 1.0);
        expect(s.buttons, bit, reason: '$button should map to bit $bit');
      });
    });

    test('home/touchpad are ignored (no frame bit)', () {
      state.applyButton(gp.GamepadButton.home, 1.0);
      state.applyButton(gp.GamepadButton.touchpad, 1.0);
      expect(state.buttons, 0);
    });
  });

  group('trigger folding', () {
    test('digital trigger button → full/zero value', () {
      state.applyButton(gp.GamepadButton.leftTrigger, 1.0);
      expect(state.leftTrigger, GamepadFrameBits.triggerMax);
      state.applyButton(gp.GamepadButton.leftTrigger, 0.0);
      expect(state.leftTrigger, 0);
      state.applyButton(gp.GamepadButton.rightTrigger, 1.0);
      expect(state.rightTrigger, GamepadFrameBits.triggerMax);
    });

    test('analog trigger axis scales 0..1 → 0..triggerMax', () {
      state.applyAxis(gp.GamepadAxis.leftTrigger, 1.0);
      expect(state.leftTrigger, GamepadFrameBits.triggerMax);
      state.applyAxis(gp.GamepadAxis.rightTrigger, 0.5);
      expect(state.rightTrigger, (0.5 * GamepadFrameBits.triggerMax).round());
    });
  });

  group('stick axis folding (value -1..1 → -axisMax..axisMax)', () {
    test('left stick X full deflection both ways', () {
      state.applyAxis(gp.GamepadAxis.leftStickX, 1.0);
      expect(state.stickX, GamepadFrameBits.axisMax);
      state.applyAxis(gp.GamepadAxis.leftStickX, -1.0);
      expect(state.stickX, -GamepadFrameBits.axisMax);
    });

    test('left stick Y scales proportionally (up is +Y)', () {
      state.applyAxis(gp.GamepadAxis.leftStickY, 0.5);
      expect(state.stickY, (0.5 * GamepadFrameBits.axisMax).round());
    });

    test('right stick is ignored (left stick = navigation)', () {
      state.applyAxis(gp.GamepadAxis.rightStickX, 1.0);
      state.applyAxis(gp.GamepadAxis.rightStickY, 1.0);
      expect(state.stickX, 0);
      expect(state.stickY, 0);
    });
  });
}
