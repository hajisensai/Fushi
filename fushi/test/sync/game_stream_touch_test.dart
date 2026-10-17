import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/game_stream_touch.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

const Size _scale = Size(1000, 500);

Duration _ms(int value) => Duration(milliseconds: value);

List<GameStreamInputAction> _actions(List<GameStreamPointerCommand> list) =>
    <GameStreamInputAction>[
      for (final GameStreamPointerCommand c in list) c.action,
    ];

void main() {
  group('direct touch', () {
    test('one finger presses, drags and releases the left button', () {
      final GameStreamTouchInterpreter touch = GameStreamTouchInterpreter(
        mode: GameStreamTouchMode.direct,
      );
      final List<GameStreamPointerCommand> sent = <GameStreamPointerCommand>[
        ...touch.down(1, const Offset(.2, .2), _ms(0), pixelScale: _scale),
        ...touch.move(1, const Offset(.3, .2), _ms(10), pixelScale: _scale),
        ...touch.up(1, const Offset(.3, .2), _ms(20), pixelScale: _scale),
      ];
      expect(_actions(sent), <GameStreamInputAction>[
        GameStreamInputAction.down,
        GameStreamInputAction.move,
        GameStreamInputAction.up,
      ]);
      expect(sent.first.position, const Offset(.2, .2));
      expect(sent.last.position, const Offset(.3, .2));
      expect(touch.active, isFalse);
    });

    test('an old host ignores extra fingers and keeps the first press', () {
      final GameStreamTouchInterpreter touch = GameStreamTouchInterpreter(
        mode: GameStreamTouchMode.direct,
      );
      touch.down(1, const Offset(.2, .2), _ms(0), pixelScale: _scale);
      expect(
        touch.down(2, const Offset(.5, .5), _ms(5), pixelScale: _scale),
        isEmpty,
      );
      expect(
        touch.up(2, const Offset(.5, .5), _ms(9), pixelScale: _scale),
        isEmpty,
      );
      expect(touch.leftHeld, isTrue);
      expect(_actions(touch.cancel()), <GameStreamInputAction>[
        GameStreamInputAction.up,
      ]);
    });

    test('second finger releases the press, then a quick tap right-clicks', () {
      final GameStreamTouchInterpreter touch = GameStreamTouchInterpreter(
        mode: GameStreamTouchMode.direct,
        rightClickSupported: true,
      );
      touch.down(1, const Offset(.4, .4), _ms(0), pixelScale: _scale);
      final List<GameStreamPointerCommand> second = touch.down(
        2,
        const Offset(.45, .4),
        _ms(30),
        pixelScale: _scale,
      );
      expect(_actions(second), <GameStreamInputAction>[
        GameStreamInputAction.up,
      ]);
      touch.up(2, const Offset(.45, .4), _ms(80), pixelScale: _scale);
      final List<GameStreamPointerCommand> end = touch.up(
        1,
        const Offset(.4, .4),
        _ms(90),
        pixelScale: _scale,
      );
      expect(end, <GameStreamPointerCommand>[
        const GameStreamPointerCommand.down(Offset(.4, .4), button: 'right'),
        const GameStreamPointerCommand.up(Offset(.4, .4), button: 'right'),
      ]);
    });
  });

  group('trackpad', () {
    test('drag moves the cursor relatively and a tap clicks in place', () {
      final GameStreamTouchInterpreter touch = GameStreamTouchInterpreter(
        mode: GameStreamTouchMode.trackpad,
        trackpadSensitivity: 1,
      );
      expect(
        touch.down(1, const Offset(.9, .9), _ms(0), pixelScale: _scale),
        isEmpty,
        reason: 'Touching a trackpad never clicks by itself',
      );
      final List<GameStreamPointerCommand> moved = touch.move(
        1,
        const Offset(.8, .9),
        _ms(20),
        pixelScale: _scale,
      );
      expect(moved.single.action, GameStreamInputAction.move);
      expect(moved.single.position.dx, closeTo(.4, 1e-9));
      touch.up(1, const Offset(.8, .9), _ms(40), pixelScale: _scale);

      touch.down(1, const Offset(.1, .1), _ms(1000), pixelScale: _scale);
      final List<GameStreamPointerCommand> tap = touch.up(
        1,
        const Offset(.1, .1),
        _ms(1100),
        pixelScale: _scale,
      );
      expect(_actions(tap), <GameStreamInputAction>[
        GameStreamInputAction.down,
        GameStreamInputAction.up,
      ]);
      expect(tap.first.position.dx, closeTo(.4, 1e-9));
    });

    test('hold then drag performs a left drag', () {
      final GameStreamTouchInterpreter touch = GameStreamTouchInterpreter(
        mode: GameStreamTouchMode.trackpad,
      );
      touch.down(1, const Offset(.5, .5), _ms(0), pixelScale: _scale);
      final List<GameStreamPointerCommand> drag = touch.move(
        1,
        const Offset(.52, .5),
        _ms(600),
        pixelScale: _scale,
      );
      expect(_actions(drag), <GameStreamInputAction>[
        GameStreamInputAction.down,
        GameStreamInputAction.move,
      ]);
      expect(
        _actions(
          touch.up(1, const Offset(.52, .5), _ms(700), pixelScale: _scale),
        ),
        <GameStreamInputAction>[GameStreamInputAction.up],
      );
    });

    test('two-finger drag scrolls in whole notches, never clicks', () {
      final GameStreamTouchInterpreter touch = GameStreamTouchInterpreter(
        mode: GameStreamTouchMode.trackpad,
        wheelSupported: true,
        rightClickSupported: true,
      );
      touch.down(1, const Offset(.5, .5), _ms(0), pixelScale: _scale);
      touch.down(2, const Offset(.6, .5), _ms(5), pixelScale: _scale);
      final List<GameStreamPointerCommand> wheel = <GameStreamPointerCommand>[
        // Both fingers move 0.3 * 500 = 150 px up → ~4 notches downwards.
        ...touch.move(1, const Offset(.5, .2), _ms(40), pixelScale: _scale),
        ...touch.move(2, const Offset(.6, .2), _ms(45), pixelScale: _scale),
      ];
      expect(
        wheel.every(
          (GameStreamPointerCommand c) =>
              c.action == GameStreamInputAction.wheel,
        ),
        isTrue,
      );
      final double notches = wheel.fold<double>(
        0,
        (double sum, GameStreamPointerCommand c) => sum + (c.dy ?? 0),
      );
      expect(notches, 4);
      touch.up(1, const Offset(.5, .2), _ms(60), pixelScale: _scale);
      expect(
        touch.up(2, const Offset(.6, .2), _ms(70), pixelScale: _scale),
        isEmpty,
        reason: 'A scroll must not end in a right click',
      );
    });

    test('cancel releases a held drag exactly once', () {
      final GameStreamTouchInterpreter touch = GameStreamTouchInterpreter(
        mode: GameStreamTouchMode.trackpad,
      );
      touch.down(1, const Offset(.5, .5), _ms(0), pixelScale: _scale);
      touch.move(1, const Offset(.51, .5), _ms(600), pixelScale: _scale);
      expect(_actions(touch.cancel()), <GameStreamInputAction>[
        GameStreamInputAction.up,
      ]);
      expect(touch.cancel(), isEmpty);
    });
  });

  group('GameStreamMouseInterpreter', () {
    const Offset a = Offset(.25, .5);
    const Offset b = Offset(.75, .5);

    test('buttons press and release as themselves', () {
      final GameStreamMouseInterpreter mouse = GameStreamMouseInterpreter(
        extraButtonsSupported: true,
      );
      expect(mouse.update(a, kPrimaryMouseButton), <GameStreamPointerCommand>[
        const GameStreamPointerCommand.down(a),
      ]);
      expect(mouse.active, isTrue);
      expect(mouse.update(b, kPrimaryMouseButton), <GameStreamPointerCommand>[
        const GameStreamPointerCommand.move(b),
      ]);
      expect(mouse.update(b, 0), <GameStreamPointerCommand>[
        const GameStreamPointerCommand.up(b),
      ]);
      expect(mouse.update(a, kSecondaryMouseButton), <GameStreamPointerCommand>[
        const GameStreamPointerCommand.down(a, button: 'right'),
      ]);
      expect(mouse.update(a, 0), <GameStreamPointerCommand>[
        const GameStreamPointerCommand.up(a, button: 'right'),
      ]);
      expect(mouse.update(a, kMiddleMouseButton), <GameStreamPointerCommand>[
        const GameStreamPointerCommand.down(a, button: 'middle'),
      ]);
    });

    test('hover moves the host cursor without a button', () {
      final GameStreamMouseInterpreter mouse = GameStreamMouseInterpreter();
      expect(mouse.update(a, 0), <GameStreamPointerCommand>[
        const GameStreamPointerCommand.move(a),
      ]);
      expect(mouse.active, isFalse);
    });

    test('right/middle are swallowed when the host lacks pointer buttons', () {
      final GameStreamMouseInterpreter mouse = GameStreamMouseInterpreter();
      // Not a left click in disguise: only the motion goes through.
      expect(mouse.update(a, kSecondaryMouseButton), <GameStreamPointerCommand>[
        const GameStreamPointerCommand.move(a),
      ]);
      expect(mouse.active, isFalse);
    });

    test('wheel accumulates logical pixels into host notches', () {
      final GameStreamMouseInterpreter mouse = GameStreamMouseInterpreter(
        wheelSupported: true,
      );
      expect(mouse.scroll(a, const Offset(0, 30)), isEmpty);
      expect(mouse.scroll(a, const Offset(0, 30)), <GameStreamPointerCommand>[
        const GameStreamPointerCommand.wheel(a, dy: 1),
      ]);
      expect(mouse.scroll(a, const Offset(-120, 0)), <GameStreamPointerCommand>[
        const GameStreamPointerCommand.wheel(a, dx: -2),
      ]);
    });

    test('a platform detent size turns each detent into one notch', () {
      final GameStreamMouseInterpreter mouse = GameStreamMouseInterpreter(
        wheelSupported: true,
      );
      // Windows at 100%: one detent = 100 logical px.
      expect(
        mouse.scroll(a, const Offset(0, 100), step: 100),
        <GameStreamPointerCommand>[
          const GameStreamPointerCommand.wheel(a, dy: 1),
        ],
      );
      // A high-resolution wheel's small deltas add up instead of each
      // becoming a whole notch.
      expect(mouse.scroll(a, const Offset(0, 30), step: 100), isEmpty);
      expect(mouse.scroll(a, const Offset(0, 30), step: 100), isEmpty);
      expect(mouse.scroll(a, const Offset(0, 40), step: 100), hasLength(1));
    });

    test('no wheel without host support', () {
      final GameStreamMouseInterpreter mouse = GameStreamMouseInterpreter();
      expect(mouse.scroll(a, const Offset(0, 500)), isEmpty);
    });

    test('cancel releases every held button exactly once', () {
      final GameStreamMouseInterpreter mouse = GameStreamMouseInterpreter(
        extraButtonsSupported: true,
      );
      mouse.update(a, kPrimaryMouseButton | kSecondaryMouseButton);
      expect(mouse.cancel(), <GameStreamPointerCommand>[
        const GameStreamPointerCommand.up(a),
        const GameStreamPointerCommand.up(a, button: 'right'),
      ]);
      expect(mouse.cancel(), isEmpty);
      expect(mouse.active, isFalse);
    });
  });
}
