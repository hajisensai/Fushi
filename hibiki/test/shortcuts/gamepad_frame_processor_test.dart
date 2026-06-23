import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

void main() {
  late List<GamepadButton> buttons;
  late List<TraversalDirection> stickMoves;
  late GamepadFrameProcessor processor;

  setUp(() {
    buttons = <GamepadButton>[];
    stickMoves = <TraversalDirection>[];
    // TODO-700 T6: the stick now emits on its OWN focus-only channel
    // (onStickMove), independent of the d-pad's onButton channel.
    processor = GamepadFrameProcessor(
      onButton: buttons.add,
      onStickMove: stickMoves.add,
    );
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
      frame(GamepadFrameBits.a, nowMs: 0);
      frame(GamepadFrameBits.a, nowMs: 60); // still held
      frame(GamepadFrameBits.a, nowMs: 120); // still held
      expect(buttons, <GamepadButton>[GamepadButton.a]);
    });

    test('release then re-press fires A again', () {
      frame(GamepadFrameBits.a, nowMs: 0);
      frame(0, nowMs: 60); // released
      frame(GamepadFrameBits.a, nowMs: 120); // pressed again
      expect(buttons, <GamepadButton>[GamepadButton.a, GamepadButton.a]);
    });

    test('B/X/Y/shoulders/start/back/thumbs map correctly', () {
      frame(GamepadFrameBits.b);
      frame(0);
      frame(GamepadFrameBits.x);
      frame(0);
      frame(GamepadFrameBits.y);
      frame(0);
      frame(GamepadFrameBits.leftShoulder);
      frame(0);
      frame(GamepadFrameBits.rightShoulder);
      frame(0);
      frame(GamepadFrameBits.start);
      frame(0);
      frame(GamepadFrameBits.back);
      frame(0);
      frame(GamepadFrameBits.leftThumb);
      frame(0);
      frame(GamepadFrameBits.rightThumb);
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
      frame(0, lt: GamepadFrameBits.triggerThreshold + 1);
      frame(0, lt: 255); // still held
      frame(0, lt: 0); // released
      frame(0, rt: 200);
      expect(buttons, <GamepadButton>[GamepadButton.lt, GamepadButton.rt]);
    });

    test('a sub-threshold trigger does not fire', () {
      frame(0, lt: GamepadFrameBits.triggerThreshold); // not > threshold
      expect(buttons, isEmpty);
    });
  });

  group('A long-press (onLongPress set: mouse-like tap vs hold)', () {
    late List<GamepadButton> longPresses;
    late GamepadFrameProcessor lp;
    void lpFrame(int mask, {required int nowMs}) => lp.processFrame(
          buttons: mask,
          leftTrigger: 0,
          rightTrigger: 0,
          stickX: 0,
          stickY: 0,
          nowMs: nowMs,
        );

    setUp(() {
      buttons = <GamepadButton>[];
      longPresses = <GamepadButton>[];
      lp = GamepadFrameProcessor(
        onButton: buttons.add,
        onLongPress: longPresses.add,
      );
    });

    test('A activate is deferred to RELEASE (not the press edge)', () {
      lpFrame(GamepadFrameBits.a, nowMs: 0);
      expect(buttons, isEmpty); // nothing on press
      lpFrame(0, nowMs: 100); // released < threshold
      expect(buttons, <GamepadButton>[GamepadButton.a]);
      expect(longPresses, isEmpty);
    });

    test('holding A past the threshold fires one long-press and NO activate',
        () {
      lpFrame(GamepadFrameBits.a, nowMs: 0);
      lpFrame(GamepadFrameBits.a, nowMs: 300); // < 500ms, still nothing
      expect(longPresses, isEmpty);
      lpFrame(GamepadFrameBits.a, nowMs: 520); // ≥ 500ms → long-press
      lpFrame(GamepadFrameBits.a, nowMs: 700); // still held → no repeat
      lpFrame(0, nowMs: 800); // released → activate suppressed
      expect(longPresses, <GamepadButton>[GamepadButton.a]);
      expect(buttons, isEmpty);
    });

    test('only A is deferred; B still fires on the press edge', () {
      lpFrame(GamepadFrameBits.b, nowMs: 0);
      expect(buttons, <GamepadButton>[GamepadButton.b]);
    });
  });

  group('GamepadLongPressActions native key path', () {
    testWidgets('holding gameButtonA invokes long press without activate',
        (WidgetTester tester) async {
      int activations = 0;
      int longPresses = 0;
      final FocusNode focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GamepadLongPressActions(
              onLongPress: () => longPresses++,
              child: Actions(
                actions: <Type, Action<Intent>>{
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      activations++;
                      return null;
                    },
                  ),
                },
                child: Focus(
                  focusNode: focusNode,
                  autofocus: true,
                  child: const SizedBox(width: 20, height: 20),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pump(const Duration(milliseconds: 600));
      expect(longPresses, 1);
      expect(activations, 0);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pump();
      expect(longPresses, 1);
      expect(activations, 0);
    });
  });

  group('D-pad directional channel', () {
    test('D-pad is NOT emitted as a discrete button — it is directional', () {
      // dpadRight should produce a dpadRight button via the directional channel
      // exactly once on press (no separate non-directional emission).
      frame(GamepadFrameBits.dpadRight, nowMs: 0);
      expect(buttons, <GamepadButton>[GamepadButton.dpadRight]);
    });

    test('held D-pad auto-repeats after the initial delay', () {
      frame(GamepadFrameBits.dpadDown, nowMs: 0); // initial fire
      frame(GamepadFrameBits.dpadDown, nowMs: 100); // < repeatDelay → no repeat
      frame(GamepadFrameBits.dpadDown, nowMs: 500); // ≥ delay → repeat
      frame(GamepadFrameBits.dpadDown,
          nowMs: 560); // < interval since last → no
      frame(GamepadFrameBits.dpadDown, nowMs: 620); // ≥ interval → repeat
      expect(buttons, <GamepadButton>[
        GamepadButton.dpadDown,
        GamepadButton.dpadDown,
        GamepadButton.dpadDown,
      ]);
    });

    test('releasing the D-pad stops the repeat and re-press fires immediately',
        () {
      frame(GamepadFrameBits.dpadLeft, nowMs: 0);
      frame(0, nowMs: 500); // released — no repeat
      frame(GamepadFrameBits.dpadLeft, nowMs: 600); // fresh press
      expect(buttons, <GamepadButton>[
        GamepadButton.dpadLeft,
        GamepadButton.dpadLeft,
      ]);
    });

    test('changing D-pad direction fires the new direction immediately', () {
      frame(GamepadFrameBits.dpadUp, nowMs: 0);
      frame(GamepadFrameBits.dpadRight, nowMs: 60); // direction change
      expect(buttons, <GamepadButton>[
        GamepadButton.dpadUp,
        GamepadButton.dpadRight,
      ]);
    });
  });

  // TODO-700 T6: the LEFT STICK is its OWN focus-only directional channel
  // (onStickMove → TraversalDirection), decoupled from the d-pad's onButton
  // channel. It NEVER emits dpad* buttons (so it can never reach the registry /
  // lookup), but keeps the SAME dead-zone hysteresis + held-direction auto-repeat
  // (TODO-699 feel preserved).
  group('left stick → focus-only onStickMove channel (decoupled from D-pad)',
      () {
    test('below the enter threshold the stick is ignored', () {
      frame(0, lx: 15000, nowMs: 0); // < stickEnter (18000)
      expect(stickMoves, isEmpty);
      expect(buttons, isEmpty);
    });

    test('past the enter threshold emits the matching direction (up is +Y)',
        () {
      frame(0, ly: 30000, nowMs: 0);
      expect(stickMoves, <TraversalDirection>[TraversalDirection.up]);
      // CRITICAL: the stick must NOT emit a dpad* button — that channel is the
      // bindable / lookup path, which the stick must never touch.
      expect(buttons, isEmpty);
    });

    test('hysteresis: stays active between exit and enter, releases below exit',
        () {
      frame(0, lx: 30000, nowMs: 0); // enter → right
      frame(0, lx: 13000, nowMs: 500); // between exit/enter, ≥ delay → repeat
      frame(0, lx: 5000, nowMs: 1000); // below exit → released, no fire
      expect(stickMoves, <TraversalDirection>[
        TraversalDirection.right,
        TraversalDirection.right,
      ]);
      expect(buttons, isEmpty);
    });

    test('held stick auto-repeats on its own clock after the initial delay',
        () {
      frame(0, ly: 30000, nowMs: 0); // initial fire (up)
      frame(0, ly: 30000, nowMs: 100); // < repeatDelay → no repeat
      frame(0, ly: 30000, nowMs: 500); // ≥ delay → repeat
      frame(0, ly: 30000, nowMs: 560); // < interval → no
      frame(0, ly: 30000, nowMs: 620); // ≥ interval → repeat
      expect(stickMoves, <TraversalDirection>[
        TraversalDirection.up,
        TraversalDirection.up,
        TraversalDirection.up,
      ]);
      expect(buttons, isEmpty);
    });

    test('D-pad and stick are independent channels (both fire, on their own)',
        () {
      // D-pad left held + stick pushed right: the d-pad emits its button, the
      // stick emits its (opposite) direction — they no longer collapse into one.
      frame(GamepadFrameBits.dpadLeft, lx: 30000, nowMs: 0);
      expect(buttons, <GamepadButton>[GamepadButton.dpadLeft]);
      expect(stickMoves, <TraversalDirection>[TraversalDirection.right]);
    });

    test('a null onStickMove makes the stick a no-op (not a dpad fallback)',
        () {
      final List<GamepadButton> b2 = <GamepadButton>[];
      final GamepadFrameProcessor noStick =
          GamepadFrameProcessor(onButton: b2.add); // onStickMove omitted
      noStick.processFrame(
        buttons: 0,
        leftTrigger: 0,
        rightTrigger: 0,
        stickX: 0,
        stickY: 30000,
        nowMs: 0,
      );
      expect(b2, isEmpty);
    });
  });

  group('reset', () {
    test('reset clears held/edge state so the next frame fires fresh', () {
      frame(GamepadFrameBits.a, nowMs: 0);
      processor.reset();
      frame(GamepadFrameBits.a, nowMs: 60); // would be "held" without reset
      expect(buttons, <GamepadButton>[GamepadButton.a, GamepadButton.a]);
    });
  });
}
