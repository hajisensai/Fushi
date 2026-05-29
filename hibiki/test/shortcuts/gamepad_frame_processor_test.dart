import 'package:flutter_test/flutter_test.dart';
import 'package:win32/win32.dart';

import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

void main() {
  late List<GamepadButton> buttons;
  late XInputFrameProcessor processor;

  setUp(() {
    buttons = <GamepadButton>[];
    processor = XInputFrameProcessor(onButton: buttons.add);
  });

  // Convenience: a centred-stick, no-trigger frame with the given button mask.
  void frame(int mask,
      {int nowMs = 0, int lx = 0, int ly = 0, int lt = 0, int rt = 0}) {
    processor.processFrame(
      buttons: mask,
      leftTrigger: lt,
      rightTrigger: rt,
      stickX: lx,
      stickY: ly,
      nowMs: nowMs,
    );
  }

  group('discrete buttons (edge detection)', () {
    test('A fires once on press, not while held', () {
      frame(XINPUT_GAMEPAD_A, nowMs: 0);
      frame(XINPUT_GAMEPAD_A, nowMs: 60); // still held
      frame(XINPUT_GAMEPAD_A, nowMs: 120); // still held
      expect(buttons, <GamepadButton>[GamepadButton.a]);
    });

    test('release then re-press fires A again', () {
      frame(XINPUT_GAMEPAD_A, nowMs: 0);
      frame(0, nowMs: 60); // released
      frame(XINPUT_GAMEPAD_A, nowMs: 120); // pressed again
      expect(buttons, <GamepadButton>[GamepadButton.a, GamepadButton.a]);
    });

    test('B/X/Y/shoulders/start/back/thumbs map correctly', () {
      frame(XINPUT_GAMEPAD_B);
      frame(0);
      frame(XINPUT_GAMEPAD_X);
      frame(0);
      frame(XINPUT_GAMEPAD_Y);
      frame(0);
      frame(XINPUT_GAMEPAD_LEFT_SHOULDER);
      frame(0);
      frame(XINPUT_GAMEPAD_RIGHT_SHOULDER);
      frame(0);
      frame(XINPUT_GAMEPAD_START);
      frame(0);
      frame(XINPUT_GAMEPAD_BACK);
      frame(0);
      frame(XINPUT_GAMEPAD_LEFT_THUMB);
      frame(0);
      frame(XINPUT_GAMEPAD_RIGHT_THUMB);
      expect(buttons, <GamepadButton>[
        GamepadButton.b,
        GamepadButton.x,
        GamepadButton.y,
        GamepadButton.lb,
        GamepadButton.rb,
        GamepadButton.start,
        GamepadButton.select,
        GamepadButton.thumbLeft,
        GamepadButton.thumbRight,
      ]);
    });

    test('triggers fire as lt/rt past the threshold, once per press', () {
      frame(0, lt: XINPUT_GAMEPAD_TRIGGER_THRESHOLD + 1);
      frame(0, lt: 255); // still held
      frame(0, lt: 0); // released
      frame(0, rt: 200);
      expect(buttons, <GamepadButton>[GamepadButton.lt, GamepadButton.rt]);
    });

    test('a sub-threshold trigger does not fire', () {
      frame(0, lt: XINPUT_GAMEPAD_TRIGGER_THRESHOLD); // not > threshold
      expect(buttons, isEmpty);
    });
  });

  group('D-pad directional channel', () {
    test('D-pad is NOT emitted as a discrete button — it is directional', () {
      // dpadRight should produce a dpadRight button via the directional channel
      // exactly once on press (no separate non-directional emission).
      frame(XINPUT_GAMEPAD_DPAD_RIGHT, nowMs: 0);
      expect(buttons, <GamepadButton>[GamepadButton.dpadRight]);
    });

    test('held D-pad auto-repeats after the initial delay', () {
      frame(XINPUT_GAMEPAD_DPAD_DOWN, nowMs: 0); // initial fire
      frame(XINPUT_GAMEPAD_DPAD_DOWN, nowMs: 100); // < repeatDelay → no repeat
      frame(XINPUT_GAMEPAD_DPAD_DOWN, nowMs: 500); // ≥ delay → repeat
      frame(XINPUT_GAMEPAD_DPAD_DOWN, nowMs: 560); // < interval since last → no
      frame(XINPUT_GAMEPAD_DPAD_DOWN, nowMs: 620); // ≥ interval → repeat
      expect(buttons, <GamepadButton>[
        GamepadButton.dpadDown,
        GamepadButton.dpadDown,
        GamepadButton.dpadDown,
      ]);
    });

    test('releasing the D-pad stops the repeat and re-press fires immediately',
        () {
      frame(XINPUT_GAMEPAD_DPAD_LEFT, nowMs: 0);
      frame(0, nowMs: 500); // released — no repeat
      frame(XINPUT_GAMEPAD_DPAD_LEFT, nowMs: 600); // fresh press
      expect(buttons, <GamepadButton>[
        GamepadButton.dpadLeft,
        GamepadButton.dpadLeft,
      ]);
    });

    test('changing D-pad direction fires the new direction immediately', () {
      frame(XINPUT_GAMEPAD_DPAD_UP, nowMs: 0);
      frame(XINPUT_GAMEPAD_DPAD_RIGHT, nowMs: 60); // direction change
      expect(buttons, <GamepadButton>[
        GamepadButton.dpadUp,
        GamepadButton.dpadRight,
      ]);
    });
  });

  group('left stick → D-pad button with hysteresis (unified with D-pad)', () {
    test('below the enter threshold the stick is ignored', () {
      frame(0, lx: 15000, nowMs: 0); // < stickEnter (18000)
      expect(buttons, isEmpty);
    });

    test('past the enter threshold emits the matching dpad button (up is +Y)',
        () {
      frame(0, ly: 30000, nowMs: 0);
      expect(buttons, <GamepadButton>[GamepadButton.dpadUp]);
    });

    test('hysteresis: stays active between exit and enter, releases below exit',
        () {
      frame(0, lx: 30000, nowMs: 0); // enter → dpadRight
      frame(0, lx: 13000, nowMs: 500); // between exit/enter, ≥ delay → repeat
      frame(0, lx: 5000, nowMs: 1000); // below exit → released, no fire
      expect(buttons, <GamepadButton>[
        GamepadButton.dpadRight,
        GamepadButton.dpadRight,
      ]);
    });

    test('D-pad wins over the stick when both point different ways', () {
      frame(XINPUT_GAMEPAD_DPAD_LEFT, lx: 30000, nowMs: 0);
      expect(buttons, <GamepadButton>[GamepadButton.dpadLeft]);
    });
  });

  group('reset', () {
    test('reset clears held/edge state so the next frame fires fresh', () {
      frame(XINPUT_GAMEPAD_A, nowMs: 0);
      processor.reset();
      frame(XINPUT_GAMEPAD_A, nowMs: 60); // would be "held" without reset
      expect(buttons, <GamepadButton>[GamepadButton.a, GamepadButton.a]);
    });
  });
}
