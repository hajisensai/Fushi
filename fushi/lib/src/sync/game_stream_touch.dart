import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter/gestures.dart'
    show kMiddleMouseButton, kPrimaryMouseButton, kSecondaryMouseButton;

import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

/// How touches on the video become host mouse input (Moonlight's two modes).
enum GameStreamTouchMode {
  /// The finger is the cursor: touch down = left press at that point.
  direct,

  /// The screen is a laptop trackpad driving a visible cursor.
  trackpad,
}

/// One pointer instruction for the host, in normalized client coordinates.
class GameStreamPointerCommand {
  const GameStreamPointerCommand.move(this.position)
    : action = GameStreamInputAction.move,
      button = null,
      dx = null,
      dy = null;

  const GameStreamPointerCommand.down(this.position, {this.button = 'left'})
    : action = GameStreamInputAction.down,
      dx = null,
      dy = null;

  const GameStreamPointerCommand.up(this.position, {this.button = 'left'})
    : action = GameStreamInputAction.up,
      dx = null,
      dy = null;

  const GameStreamPointerCommand.wheel(this.position, {this.dx, this.dy})
    : action = GameStreamInputAction.wheel,
      button = null;

  final GameStreamInputAction action;
  final Offset position;
  final String? button;
  final double? dx;
  final double? dy;

  @override
  bool operator ==(Object other) =>
      other is GameStreamPointerCommand &&
      other.action == action &&
      other.position == position &&
      other.button == button &&
      other.dx == dx &&
      other.dy == dy;

  @override
  int get hashCode => Object.hash(action, position, button, dx, dy);

  @override
  String toString() =>
      'GameStreamPointerCommand(${action.name}, $position, $button, $dx, $dy)';
}

/// Multi-touch interpreter for the stream surface. Positions are normalized
/// 0..1 within the video content; `pixelScale` converts normalized deltas to
/// logical pixels for tap/scroll thresholds.
///
/// * Direct: one finger presses the left button where it touches. A second
///   finger first releases that press, then two-finger tap = right click and
///   two-finger drag = wheel.
/// * Trackpad: one-finger drag moves the cursor, tap = left click, hold then
///   drag = left drag, two-finger tap = right click, two-finger drag = wheel.
///
/// Right click and wheel are emitted only when the host advertises them;
/// otherwise the gesture is swallowed rather than misreported as a left
/// click.
class GameStreamTouchInterpreter {
  GameStreamTouchInterpreter({
    required this.mode,
    this.rightClickSupported = false,
    this.wheelSupported = false,
    this.trackpadSensitivity = 1.2,
    Offset initialCursor = const Offset(.5, .5),
  }) : _cursor = initialCursor;

  final GameStreamTouchMode mode;
  final bool rightClickSupported;
  final bool wheelSupported;
  final double trackpadSensitivity;

  static const double tapSlop = 12;
  static const Duration tapTimeout = Duration(milliseconds: 250);
  static const Duration holdTimeout = Duration(milliseconds: 450);

  /// Logical pixels per notch of two-finger scrolling.
  static const double scrollStep = 36;

  final Map<int, Offset> _touches = <int, Offset>{};
  final Map<int, Offset> _starts = <int, Offset>{};
  Offset _cursor;
  Duration? _firstDownAt;
  int _maxTouches = 0;
  bool _leftHeld = false;
  bool _moved = false;
  bool _scrolled = false;
  double _scrollRemainderX = 0;
  double _scrollRemainderY = 0;

  /// Cursor shown in trackpad mode (normalized).
  Offset get cursor => _cursor;
  bool get leftHeld => _leftHeld;
  bool get active => _touches.isNotEmpty;

  List<GameStreamPointerCommand> down(
    int pointer,
    Offset position,
    Duration time, {
    required Size pixelScale,
  }) {
    final List<GameStreamPointerCommand> out = <GameStreamPointerCommand>[];
    // Without right click or wheel on the host there is no two-finger
    // gesture to recognize: extra fingers are ignored and the first finger
    // keeps its press (the pre-gesture behaviour older hosts rely on).
    if (_touches.isNotEmpty && !rightClickSupported && !wheelSupported) {
      return out;
    }
    if (_touches.isEmpty) {
      _firstDownAt = time;
      _maxTouches = 0;
      _moved = false;
      _scrolled = false;
      _scrollRemainderX = 0;
      _scrollRemainderY = 0;
    }
    _touches[pointer] = position;
    _starts[pointer] = position;
    _maxTouches = math.max(_maxTouches, _touches.length);
    if (_touches.length == 1 && mode == GameStreamTouchMode.direct) {
      _cursor = position;
      _leftHeld = true;
      out.add(GameStreamPointerCommand.down(position));
    } else if (_touches.length == 2 && _leftHeld) {
      // Second finger: this is a two-finger gesture, not a press/drag.
      _leftHeld = false;
      out.add(GameStreamPointerCommand.up(_cursor));
    }
    return out;
  }

  List<GameStreamPointerCommand> move(
    int pointer,
    Offset position,
    Duration time, {
    required Size pixelScale,
  }) {
    final Offset? previous = _touches[pointer];
    if (previous == null) return const <GameStreamPointerCommand>[];
    _touches[pointer] = position;
    // Stillness before this move decides hold-to-drag: the first real motion
    // after the hold timeout starts the drag instead of cancelling it.
    final bool wasStill = !_moved;
    final Offset start = _starts[pointer] ?? position;
    if (_pixels(position - start, pixelScale) > tapSlop) _moved = true;
    final List<GameStreamPointerCommand> out = <GameStreamPointerCommand>[];
    if (_touches.length >= 2) {
      if (!wheelSupported) return out;
      // Average the fingers' motion; natural scrolling (content follows).
      final Offset delta = Offset(
        (position.dx - previous.dx) * pixelScale.width / _touches.length,
        (position.dy - previous.dy) * pixelScale.height / _touches.length,
      );
      _scrollRemainderX -= delta.dx;
      _scrollRemainderY -= delta.dy;
      final int notchesX = (_scrollRemainderX / scrollStep).truncate();
      final int notchesY = (_scrollRemainderY / scrollStep).truncate();
      if (notchesX != 0 || notchesY != 0) {
        _scrolled = true;
        _scrollRemainderX -= notchesX * scrollStep;
        _scrollRemainderY -= notchesY * scrollStep;
        out.add(
          GameStreamPointerCommand.wheel(
            _cursor,
            dx: notchesX == 0 ? null : notchesX.toDouble().clamp(-20, 20),
            dy: notchesY == 0 ? null : notchesY.toDouble().clamp(-20, 20),
          ),
        );
      }
      return out;
    }
    if (mode == GameStreamTouchMode.direct) {
      if (!_leftHeld) return out;
      _cursor = position;
      out.add(GameStreamPointerCommand.move(position));
      return out;
    }
    // Trackpad: a still finger held past holdTimeout starts a left drag.
    if (!_leftHeld &&
        wasStill &&
        _maxTouches == 1 &&
        _firstDownAt != null &&
        time - _firstDownAt! >= holdTimeout) {
      _leftHeld = true;
      out.add(GameStreamPointerCommand.down(_cursor));
    }
    final Offset next = Offset(
      (_cursor.dx + (position.dx - previous.dx) * trackpadSensitivity).clamp(
        0.0,
        1.0,
      ),
      (_cursor.dy + (position.dy - previous.dy) * trackpadSensitivity).clamp(
        0.0,
        1.0,
      ),
    );
    if (next != _cursor) {
      _cursor = next;
      out.add(GameStreamPointerCommand.move(next));
    }
    return out;
  }

  List<GameStreamPointerCommand> up(
    int pointer,
    Offset position,
    Duration time, {
    required Size pixelScale,
  }) {
    if (!_touches.containsKey(pointer)) {
      return const <GameStreamPointerCommand>[];
    }
    _touches.remove(pointer);
    _starts.remove(pointer);
    final List<GameStreamPointerCommand> out = <GameStreamPointerCommand>[];
    if (_touches.isNotEmpty) return out;
    final bool quick =
        _firstDownAt != null && time - _firstDownAt! <= tapTimeout;
    if (_maxTouches >= 2) {
      if (!_scrolled && !_moved && quick && rightClickSupported) {
        out
          ..add(GameStreamPointerCommand.down(_cursor, button: 'right'))
          ..add(GameStreamPointerCommand.up(_cursor, button: 'right'));
      }
    } else if (mode == GameStreamTouchMode.direct) {
      if (_leftHeld) {
        _cursor = position;
        out.add(GameStreamPointerCommand.up(position));
      }
    } else if (_leftHeld) {
      out.add(GameStreamPointerCommand.up(_cursor));
    } else if (!_moved && quick) {
      out
        ..add(GameStreamPointerCommand.down(_cursor))
        ..add(GameStreamPointerCommand.up(_cursor));
    }
    _leftHeld = false;
    _maxTouches = 0;
    _firstDownAt = null;
    return out;
  }

  /// Cancel / layout change / backgrounding: release what the host holds.
  List<GameStreamPointerCommand> cancel() {
    _touches.clear();
    _starts.clear();
    _maxTouches = 0;
    _firstDownAt = null;
    if (!_leftHeld) return const <GameStreamPointerCommand>[];
    _leftHeld = false;
    return <GameStreamPointerCommand>[GameStreamPointerCommand.up(_cursor)];
  }

  static double _pixels(Offset normalizedDelta, Size scale) => Offset(
    normalizedDelta.dx * scale.width,
    normalizedDelta.dy * scale.height,
  ).distance;
}

/// Desktop mouse for the stream surface. A mouse already is a pointer, so
/// unlike [GameStreamTouchInterpreter] there are no gestures: each button
/// presses and releases as itself, motion moves the host cursor whether or not
/// a button is held (hover-highlighted menus need it), and the wheel or a
/// trackpad's two-finger pan scrolls.
///
/// Right/middle buttons and the wheel are emitted only when the host
/// advertises them; an unsupported button is swallowed rather than sent as a
/// left click.
class GameStreamMouseInterpreter {
  GameStreamMouseInterpreter({
    this.extraButtonsSupported = false,
    this.wheelSupported = false,
  });

  final bool extraButtonsSupported;
  final bool wheelSupported;

  /// Logical pixels of trackpad pan per host wheel notch. A mouse wheel passes
  /// its platform's detent size to [scroll] instead.
  static const double scrollStep = 50;

  static const List<(int, String)> _buttons = <(int, String)>[
    (kPrimaryMouseButton, 'left'),
    (kSecondaryMouseButton, 'right'),
    (kMiddleMouseButton, 'middle'),
  ];

  int _held = 0;
  Offset _position = const Offset(.5, .5);
  double _scrollRemainderX = 0;
  double _scrollRemainderY = 0;

  /// Whether any button is currently pressed on the host.
  bool get active => _held != 0;

  /// The pointer is at [position] with Flutter's [buttons] bitmask held.
  /// Buttons that changed press or release; with no change it is a move.
  List<GameStreamPointerCommand> update(Offset position, int buttons) {
    _position = position;
    final List<GameStreamPointerCommand> out = <GameStreamPointerCommand>[];
    for (final (int mask, String name) in _buttons) {
      if (mask != kPrimaryMouseButton && !extraButtonsSupported) continue;
      final bool was = _held & mask != 0;
      final bool now = buttons & mask != 0;
      if (was == now) continue;
      if (now) {
        _held |= mask;
        out.add(GameStreamPointerCommand.down(position, button: name));
      } else {
        _held &= ~mask;
        out.add(GameStreamPointerCommand.up(position, button: name));
      }
    }
    if (out.isEmpty) out.add(GameStreamPointerCommand.move(position));
    return out;
  }

  /// A wheel / trackpad scroll of [delta] logical pixels at [position], one
  /// host notch per [step] pixels; positive is down/right, as Flutter reports
  /// it and the host expects.
  List<GameStreamPointerCommand> scroll(
    Offset position,
    Offset delta, {
    double step = scrollStep,
  }) {
    if (!wheelSupported) return const <GameStreamPointerCommand>[];
    _position = position;
    _scrollRemainderX += delta.dx;
    _scrollRemainderY += delta.dy;
    final int notchesX = (_scrollRemainderX / step).truncate();
    final int notchesY = (_scrollRemainderY / step).truncate();
    if (notchesX == 0 && notchesY == 0) {
      return const <GameStreamPointerCommand>[];
    }
    _scrollRemainderX -= notchesX * step;
    _scrollRemainderY -= notchesY * step;
    return <GameStreamPointerCommand>[
      GameStreamPointerCommand.wheel(
        position,
        dx: notchesX == 0 ? null : notchesX.toDouble().clamp(-20, 20),
        dy: notchesY == 0 ? null : notchesY.toDouble().clamp(-20, 20),
      ),
    ];
  }

  /// Releases every held button (focus loss, layout change, disposal).
  List<GameStreamPointerCommand> cancel() {
    final List<GameStreamPointerCommand> out = <GameStreamPointerCommand>[
      for (final (int mask, String name) in _buttons)
        if (_held & mask != 0)
          GameStreamPointerCommand.up(_position, button: name),
    ];
    _held = 0;
    _scrollRemainderX = 0;
    _scrollRemainderY = 0;
    return out;
  }
}
