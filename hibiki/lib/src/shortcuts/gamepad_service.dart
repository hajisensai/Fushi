import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
// XInput bindings (XInputGetState / XINPUT_STATE / XINPUT_GAMEPAD_* constants).
import 'package:win32/win32.dart';

import 'package:hibiki/src/shortcuts/input_binding.dart';

/// Intent dispatched for a physical gamepad button on platforms where Flutter
/// does NOT deliver `gameButton*` key events (desktop). The active page
/// (reader/home) registers an [Actions] handler that resolves it against the
/// shortcut registry for its own scope — so polled desktop input ends at the
/// exact same actions as Android's native key-event path.
///
/// The handler must return `true` when it consumed the button (so the service
/// knows not to apply the global navigation fallback) and `false`/null
/// otherwise.
@immutable
class GamepadButtonIntent extends Intent {
  const GamepadButtonIntent(this.button);

  final GamepadButton button;
}

/// Bridges physical game controllers into Hibiki's input pipeline on platforms
/// where the Flutter engine does NOT surface controller buttons as
/// `LogicalKeyboardKey.gameButton*` key events.
///
/// - **Android/iOS**: the engine already delivers gamepad buttons / D-pad as
///   key events, which the reader/home `Focus.onKeyEvent` handlers resolve. The
///   service is a no-op there (starting it would double-deliver).
/// - **Windows**: polls XInput (via the bundled `win32` FFI bindings — no native
///   build, no extra DLL; `xinput1_4.dll` ships with Windows) and translates
///   button/stick state into the SAME action set.
/// - **Linux/macOS**: no source wired yet (would need evdev / GameController);
///   the service simply does nothing, leaving room to add a source later.
///
/// Dispatch order for one button mirrors the key-event path:
///   1. [GamepadButtonIntent] → the active page's registry-resolved action;
///   2. else A → [ActivateIntent], B → global back (maybePop),
///      D-pad → [DirectionalFocusIntent] (focus traversal, same as arrow keys).
class GamepadService {
  GamepadService({required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  _WindowsGamepadPoller? _poller;

  /// Whether the current platform needs the polled service. Android/iOS use
  /// native key events; only desktop platforms (currently Windows) poll.
  static bool get isSupportedPlatform => Platform.isWindows;

  void start() {
    if (_poller != null) return;
    if (!Platform.isWindows) return; // only source implemented so far
    _poller = _WindowsGamepadPoller(
      processor: XInputFrameProcessor(onButton: _dispatchButton),
    )..start();
  }

  void dispose() {
    _poller?.dispose();
    _poller = null;
  }

  BuildContext? get _dispatchContext =>
      FocusManager.instance.primaryFocus?.context ??
      navigatorKey.currentContext;

  /// Routes a discrete button press. D-pad buttons are routed here too so the
  /// reader's registry page-turn bindings (e.g. D-pad-right → page forward)
  /// fire; when unbound in the active scope they fall back to directional focus.
  void _dispatchButton(GamepadButton button) {
    final BuildContext? ctx = _dispatchContext;
    if (ctx == null) return;
    _forceTraditionalHighlight();

    final bool handled = Actions.maybeInvoke<GamepadButtonIntent>(
          ctx,
          GamepadButtonIntent(button),
        ) ==
        true;
    if (handled) return;

    switch (button) {
      case GamepadButton.a:
        Actions.maybeInvoke<ActivateIntent>(ctx, const ActivateIntent());
        return;
      case GamepadButton.b:
        navigatorKey.currentState?.maybePop();
        return;
      case GamepadButton.dpadUp:
      case GamepadButton.dpadDown:
      case GamepadButton.dpadLeft:
      case GamepadButton.dpadRight:
        final TraversalDirection? dir = _dpadDirectionOf(button);
        if (dir != null) gamepadMoveFocusInDirection(ctx, dir);
        return;
      default:
        return;
    }
  }

  // Gamepad input is polled, not delivered as key events, so the FocusManager
  // never leaves touch-highlight mode on its own — which keeps the focus ring
  // (and any focus-driven visuals) hidden. Force the keyboard/traditional
  // highlight the first time the controller is used so directional navigation
  // is actually visible.
  //
  // DELIBERATE one-way switch: the service only runs on desktop (Windows),
  // which is keyboard/gamepad-first, so once any hardware navigation happens we
  // keep the focus ring visible for the rest of the session rather than letting
  // a stray mouse move hide it mid-navigation. (On a hybrid touch device this
  // means the ring stays after a controller is used; acceptable for the desktop
  // target. Revisit if touch-first desktop use becomes common.)
  bool _highlightForced = false;
  void _forceTraditionalHighlight() {
    if (_highlightForced) return;
    _highlightForced = true;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  }

  static TraversalDirection? _dpadDirectionOf(GamepadButton button) {
    switch (button) {
      case GamepadButton.dpadUp:
        return TraversalDirection.up;
      case GamepadButton.dpadDown:
        return TraversalDirection.down;
      case GamepadButton.dpadLeft:
        return TraversalDirection.left;
      case GamepadButton.dpadRight:
        return TraversalDirection.right;
      default:
        return null;
    }
  }
}

/// Moves keyboard/gamepad focus one step in [direction] from the focus tree
/// rooted at [context]. Used by the gamepad service (and unit-tested directly).
///
/// Strategy — predictable, never a random jump:
///  * Nothing usefully focused → bootstrap onto the first focusable in the
///    scope, so the first directional press lands somewhere visible.
///  * A control is focused → move geometrically in [direction]; if there is no
///    focusable that way (e.g. moving down off an app-bar with no control
///    directly beneath it) fall back to reading-order traversal so the user can
///    still progress: down/right = next, up/left = previous.
///
/// Returns whether focus actually changed.
bool gamepadMoveFocusInDirection(
  BuildContext context,
  TraversalDirection direction,
) {
  final FocusNode? primary = FocusManager.instance.primaryFocus;
  // Bootstrap when nothing is usefully focused: null, a scope, a non-focusable
  // node, or a skip-traversal wrapper (e.g. a full-page key-event sink — moving
  // "in a direction" from its whole-screen rect is meaningless, so jump to the
  // first real control instead).
  if (primary == null ||
      primary is FocusScopeNode ||
      !primary.canRequestFocus ||
      primary.skipTraversal) {
    return FocusScope.of(context).nextFocus();
  }
  if (primary.focusInDirection(direction)) return true;
  switch (direction) {
    case TraversalDirection.down:
    case TraversalDirection.right:
      return primary.nextFocus();
    case TraversalDirection.up:
    case TraversalDirection.left:
      return primary.previousFocus();
  }
}

/// Pure, platform-free normalization of XInput controller frames into Hibiki
/// [GamepadButton] presses and a single repeating directional signal.
///
/// Separated from the FFI poller so the edge-detection, analog-stick
/// dead-zone/hysteresis and auto-repeat logic can be unit-tested by feeding
/// synthetic frames with controlled timestamps.
class XInputFrameProcessor {
  XInputFrameProcessor({required this.onButton});

  /// Emits a [GamepadButton] press. The D-pad AND the left stick both map to the
  /// dpad* buttons (the stick is treated exactly like the D-pad) so a controller
  /// has ONE consistent directional behavior regardless of which stick/pad the
  /// user pushes.
  final void Function(GamepadButton button) onButton;

  static const int repeatDelayMs = 450;
  static const int repeatIntervalMs = 110;

  // Left-stick activation uses hysteresis to avoid jitter at the boundary
  // (16-bit signed axis range is -32768..32767).
  static const int stickEnter = 18000;
  static const int stickExit = 12000;

  // Discrete (edge-detected) buttons, keyed by their XInput bitmask. D-pad is
  // intentionally excluded — it drives the repeating directional channel.
  static const Map<int, GamepadButton> buttonBits = <int, GamepadButton>{
    XINPUT_GAMEPAD_A: GamepadButton.a,
    XINPUT_GAMEPAD_B: GamepadButton.b,
    XINPUT_GAMEPAD_X: GamepadButton.x,
    XINPUT_GAMEPAD_Y: GamepadButton.y,
    XINPUT_GAMEPAD_LEFT_SHOULDER: GamepadButton.lb,
    XINPUT_GAMEPAD_RIGHT_SHOULDER: GamepadButton.rb,
    XINPUT_GAMEPAD_START: GamepadButton.start,
    XINPUT_GAMEPAD_BACK: GamepadButton.select,
    XINPUT_GAMEPAD_LEFT_THUMB: GamepadButton.thumbLeft,
    XINPUT_GAMEPAD_RIGHT_THUMB: GamepadButton.thumbRight,
  };

  int _prevButtons = 0;
  bool _prevLeftTrigger = false;
  bool _prevRightTrigger = false;

  // Hysteretic stick direction (null = stick centred).
  TraversalDirection? _stickDir;

  // Repeating directional channel state.
  TraversalDirection? _heldDir;
  int _heldSinceMs = 0;
  int _lastRepeatMs = 0;

  /// Clears all transient state — call when the controller disconnects or the
  /// active controller changes, so a stale bitmask can't fire spurious edges.
  void reset() {
    _prevButtons = 0;
    _prevLeftTrigger = false;
    _prevRightTrigger = false;
    _stickDir = null;
    _heldDir = null;
  }

  void processFrame({
    required int buttons,
    required int leftTrigger,
    required int rightTrigger,
    required int stickX,
    required int stickY,
    required int nowMs,
  }) {
    // Edge-detected discrete buttons.
    for (final MapEntry<int, GamepadButton> entry in buttonBits.entries) {
      final int mask = entry.key;
      final bool down = (buttons & mask) != 0;
      final bool wasDown = (_prevButtons & mask) != 0;
      if (down && !wasDown) onButton(entry.value);
    }

    // Triggers behave as digital buttons past the standard threshold.
    final bool lt = leftTrigger > XINPUT_GAMEPAD_TRIGGER_THRESHOLD;
    if (lt && !_prevLeftTrigger) onButton(GamepadButton.lt);
    _prevLeftTrigger = lt;
    final bool rt = rightTrigger > XINPUT_GAMEPAD_TRIGGER_THRESHOLD;
    if (rt && !_prevRightTrigger) onButton(GamepadButton.rt);
    _prevRightTrigger = rt;

    _prevButtons = buttons;

    // Directional channel: D-pad wins over the stick, but both feed the same
    // dpad* button so behavior is identical.
    final TraversalDirection? dir =
        _dpadDirection(buttons) ?? _readStickDirection(stickX, stickY);
    if (dir != null) {
      _updateHeldDirection(dir, nowMs: nowMs);
    } else {
      _heldDir = null;
    }
  }

  TraversalDirection? _dpadDirection(int buttons) {
    if ((buttons & XINPUT_GAMEPAD_DPAD_UP) != 0) return TraversalDirection.up;
    if ((buttons & XINPUT_GAMEPAD_DPAD_DOWN) != 0) {
      return TraversalDirection.down;
    }
    if ((buttons & XINPUT_GAMEPAD_DPAD_LEFT) != 0) {
      return TraversalDirection.left;
    }
    if ((buttons & XINPUT_GAMEPAD_DPAD_RIGHT) != 0) {
      return TraversalDirection.right;
    }
    return null;
  }

  /// Hysteretic left-stick → direction. Up is +Y in XInput.
  TraversalDirection? _readStickDirection(int lx, int ly) {
    final int ax = lx.abs();
    final int ay = ly.abs();
    final int mag = ax > ay ? ax : ay;
    if (_stickDir == null) {
      if (mag < stickEnter) return null;
    } else {
      if (mag < stickExit) {
        _stickDir = null;
        return null;
      }
    }
    if (ax > ay) {
      _stickDir = lx > 0 ? TraversalDirection.right : TraversalDirection.left;
    } else {
      _stickDir = ly > 0 ? TraversalDirection.up : TraversalDirection.down;
    }
    return _stickDir;
  }

  void _updateHeldDirection(TraversalDirection dir, {required int nowMs}) {
    if (_heldDir != dir) {
      _heldDir = dir;
      _heldSinceMs = nowMs;
      _lastRepeatMs = nowMs;
      onButton(dpadButtonFor(dir));
      return;
    }
    if (nowMs - _heldSinceMs >= repeatDelayMs &&
        nowMs - _lastRepeatMs >= repeatIntervalMs) {
      _lastRepeatMs = nowMs;
      onButton(dpadButtonFor(dir));
    }
  }

  static GamepadButton dpadButtonFor(TraversalDirection dir) {
    switch (dir) {
      case TraversalDirection.up:
        return GamepadButton.dpadUp;
      case TraversalDirection.down:
        return GamepadButton.dpadDown;
      case TraversalDirection.left:
        return GamepadButton.dpadLeft;
      case TraversalDirection.right:
        return GamepadButton.dpadRight;
    }
  }
}

/// Polls XInput controllers on a timer and feeds frames to an
/// [XInputFrameProcessor]. Only the I/O (which slot is connected + reading the
/// raw state struct) lives here; all normalization is in the processor.
class _WindowsGamepadPoller {
  _WindowsGamepadPoller({required this.processor});

  final XInputFrameProcessor processor;

  static const Duration _pollInterval = Duration(milliseconds: 60);

  Timer? _timer;
  final Pointer<XINPUT_STATE> _statePtr = calloc<XINPUT_STATE>();
  // Monotonic clock for auto-repeat timing — immune to wall-clock/NTP/DST jumps.
  final Stopwatch _clock = Stopwatch()..start();
  int _activeIndex = -1;

  void start() {
    _timer ??= Timer.periodic(_pollInterval, (_) => _poll());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    calloc.free(_statePtr);
  }

  void _poll() {
    // XInput is loaded lazily by the win32 binding on the first call. On a
    // Windows SKU without XInput (Server Core, stripped/N images, some WINE),
    // that throws — so guard the whole poll and permanently stop the timer on
    // any failure instead of re-throwing out of every tick.
    try {
      final int index = _firstConnectedIndex();
      if (index < 0) {
        if (_activeIndex != -1) {
          _activeIndex = -1;
          processor.reset();
        }
        return;
      }
      if (index != _activeIndex) {
        _activeIndex = index;
        processor.reset();
      }

      final XINPUT_GAMEPAD pad = _statePtr.ref.Gamepad;
      processor.processFrame(
        buttons: pad.wButtons,
        leftTrigger: pad.bLeftTrigger,
        rightTrigger: pad.bRightTrigger,
        stickX: pad.sThumbLX,
        stickY: pad.sThumbLY,
        nowMs: _clock.elapsedMilliseconds,
      );
    } catch (e) {
      debugPrint('[gamepad] XInput polling disabled (unavailable): $e');
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Returns the lowest connected controller slot, or -1 if none.
  /// XInputGetState returns ERROR_SUCCESS (0) when the slot has a controller.
  int _firstConnectedIndex() {
    for (int i = 0; i < XUSER_MAX_COUNT; i++) {
      if (XInputGetState(i, _statePtr) == 0) return i;
    }
    return -1;
  }
}
