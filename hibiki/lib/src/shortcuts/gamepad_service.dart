import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
// Cross-platform controller plugin: GameInput on Windows, GameController on
// iOS/macOS, evdev/SDL on Linux. Aliased because it also exports a
// `GamepadButton` enum that would clash with Hibiki's.
import 'package:gamepads/gamepads.dart' as gp;

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

/// Intent dispatched for a physical gamepad button on platforms where Flutter
/// does NOT deliver `gameButton*` key events (desktop / Apple). The active page
/// (reader/home) registers an [Actions] handler that resolves it against the
/// shortcut registry for its own scope — so polled controller input ends at the
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

/// Intent dispatched when [button] (currently only A) is HELD past the
/// long-press threshold — the gamepad equivalent of a mouse long-press. A
/// focused widget that supports long-press maps this to the SAME callback its
/// `onLongPress` uses (see GamepadLongPressActions), so holding A does exactly
/// what long-pressing with a mouse would.
@immutable
class GamepadLongPressIntent extends Intent {
  const GamepadLongPressIntent(this.button);

  final GamepadButton button;
}

/// Wraps a focusable widget so a gamepad long-press (hold A) invokes the SAME
/// [onLongPress] callback a mouse long-press would. Place it ABOVE the widget
/// that takes focus (e.g. around a focusable list tile) so the
/// [GamepadLongPressIntent] dispatched to the focused node bubbles here. A null
/// [onLongPress] is a transparent pass-through.
class GamepadLongPressActions extends StatelessWidget {
  const GamepadLongPressActions({
    required this.onLongPress,
    required this.child,
    super.key,
  });

  final VoidCallback? onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (onLongPress == null) return child;
    return Actions(
      actions: <Type, Action<Intent>>{
        GamepadLongPressIntent: CallbackAction<GamepadLongPressIntent>(
          onInvoke: (GamepadLongPressIntent intent) {
            onLongPress!();
            return true; // handled → GamepadService skips its activate fallback
          },
        ),
      },
      child: child,
    );
  }
}

/// Internal controller "frame" bit layout (mirrors the classic XInput wButtons
/// layout). The plugin poller encodes each `gamepads` event into this bitmask so
/// [GamepadFrameProcessor] can stay a single, platform-free normalizer.
class GamepadFrameBits {
  GamepadFrameBits._();

  static const int dpadUp = 0x0001;
  static const int dpadDown = 0x0002;
  static const int dpadLeft = 0x0004;
  static const int dpadRight = 0x0008;
  static const int start = 0x0010;
  static const int back = 0x0020;
  static const int leftThumb = 0x0040;
  static const int rightThumb = 0x0080;
  static const int leftShoulder = 0x0100;
  static const int rightShoulder = 0x0200;
  static const int a = 0x1000;
  static const int b = 0x2000;
  static const int x = 0x4000;
  static const int y = 0x8000;

  /// Analog trigger range is 0..[triggerMax]; a value above this counts as a
  /// digital press.
  static const int triggerMax = 255;
  static const int triggerThreshold = 30;

  /// Stick axis magnitude range is -[axisMax]..[axisMax].
  static const int axisMax = 32767;
}

/// Bridges physical game controllers into Hibiki's input pipeline on platforms
/// where the Flutter engine does NOT surface controller buttons as
/// `LogicalKeyboardKey.gameButton*` key events.
///
/// - **Android**: the engine already delivers gamepad buttons / D-pad as key
///   events, which the reader/home `Focus.onKeyEvent` handlers resolve. The
///   service is a no-op there (starting it would double-deliver).
/// - **Windows / iOS / macOS / Linux**: uses the `gamepads` plugin (GameInput /
///   GameController / evdev), normalized through one [GamepadFrameProcessor] so
///   every platform shares the SAME normalization + dispatch path.
///
/// Every source ends at the SAME action set. Dispatch order for one button
/// mirrors the key-event path:
///   1. [GamepadButtonIntent] → the active page's registry-resolved action;
///   2. else A → [ActivateIntent], B → global back (maybePop),
///      D-pad → directional focus (same as arrow keys).
class GamepadService {
  GamepadService({required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  _PluginGamepadPoller? _poller;

  // Whether the global pointer route + key handler were installed by [start]
  // (only on supported platforms). Guards [dispose] from removing routes that
  // were never added — removeGlobalRoute asserts on an unknown route, which
  // would otherwise crash on Android (start() early-returns there) and in tests
  // that build AppModel without starting the service.
  bool _inputRoutesInstalled = false;

  /// Android delivers controllers as engine key events; every other non-web
  /// platform polls the gamepads plugin.
  static bool get isSupportedPlatform =>
      Platform.isWindows ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux;

  void start() {
    if (_poller != null) return;
    if (!isSupportedPlatform) return; // Android uses engine key events
    _poller = _PluginGamepadPoller(
      processor: GamepadFrameProcessor(
        onButton: _dispatchButton,
        onLongPress: _dispatchLongPress,
      ),
    )..start();
    // Track the active input device so the focus ring follows it (pointer →
    // hidden, hardware nav → shown). Desktop/Apple only (where this service
    // runs); Android keeps Flutter's automatic strategy.
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerGlobal);
    HardwareKeyboard.instance.addHandler(_onKey);
    _inputRoutesInstalled = true;
  }

  void dispose() {
    _poller?.dispose();
    _poller = null;
    if (_inputRoutesInstalled) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointerGlobal);
      HardwareKeyboard.instance.removeHandler(_onKey);
      _inputRoutesInstalled = false;
    }
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
    _setHighlightForHardwareNav();

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

  /// Routes a long-press (A held past the threshold) to the focused widget as a
  /// [GamepadLongPressIntent] — the gamepad equivalent of a mouse long-press.
  /// A widget that supports long-press maps the intent to the same callback its
  /// `onLongPress` uses; if nothing handles it, the long-press is a no-op.
  void _dispatchLongPress(GamepadButton button) {
    final BuildContext? ctx = _dispatchContext;
    if (ctx == null) return;
    _setHighlightForHardwareNav();
    final bool handled = Actions.maybeInvoke<GamepadLongPressIntent>(
          ctx,
          GamepadLongPressIntent(button),
        ) ==
        true;
    // The focused widget has no long-press: a hold should still do what a tap
    // does (otherwise holding A too long silently does nothing). Fall back to
    // activate so e.g. a dropdown entry is still selected on a long hold.
    if (!handled && button == GamepadButton.a) {
      Actions.maybeInvoke<ActivateIntent>(ctx, const ActivateIntent());
    }
  }

  // The focus ring follows the ACTIVE input device: hardware navigation
  // (gamepad / physical keyboard) shows it (alwaysTraditional); a pointer
  // (mouse / touch / trackpad) hides it (alwaysTouch). A polled gamepad emits no
  // FocusManager events, so the `automatic` strategy can't react to it — hence
  // we drive the strategy explicitly from each source. This is why a global
  // pointer route + a key handler are installed: clicking with the mouse should
  // NOT leave a focus ring behind ("点击正常使用不需要焦点"), while keyboard /
  // gamepad navigation should.
  void _setHighlightForHardwareNav() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  }

  void _onPointerGlobal(PointerEvent event) {
    // Any pointer (mouse/touch/trackpad) is a "pointing" device — no focus ring.
    // Hover/move included so a mouse move after gamepad nav hides the ring.
    if (event is PointerDownEvent ||
        event is PointerHoverEvent ||
        event is PointerMoveEvent ||
        event is PointerPanZoomStartEvent) {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
    }
  }

  bool _onKey(KeyEvent event) {
    // Physical keyboard navigation wants the ring; never consume the event.
    _setHighlightForHardwareNav();
    return false;
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
  final HibikiFocusController? controller =
      HibikiFocusRoot.maybeControllerOf(context);
  if (controller != null) {
    return controller.move(hibikiFocusDirectionFromTraversal(direction));
  }

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

/// Pure, platform-free normalization of controller frames into Hibiki
/// [GamepadButton] presses and a single repeating directional signal.
///
/// Frames use the [GamepadFrameBits] bitmask layout. Separated from the I/O so
/// the edge-detection, analog-stick dead-zone/hysteresis and auto-repeat logic
/// can be unit-tested by feeding synthetic frames with controlled timestamps.
class GamepadFrameProcessor {
  GamepadFrameProcessor({required this.onButton, this.onLongPress});

  /// Emits a [GamepadButton] press. The D-pad AND the left stick both map to the
  /// dpad* buttons (the stick is treated exactly like the D-pad) so a controller
  /// has ONE consistent directional behavior regardless of which stick/pad the
  /// user pushes.
  final void Function(GamepadButton button) onButton;

  /// Emits a long-press of [button] (currently only A). To mirror a mouse's
  /// tap-vs-long-press, A is decided on RELEASE: a release before [longPressMs]
  /// emits [onButton] (activate); holding past [longPressMs] emits [onLongPress]
  /// once and suppresses the activate. Null = long-press unsupported.
  final void Function(GamepadButton button)? onLongPress;

  static const int repeatDelayMs = 450;
  static const int repeatIntervalMs = 110;

  /// Hold threshold that turns A into a long-press (matches mouse long-press).
  static const int longPressMs = 500;

  // Left-stick activation uses hysteresis to avoid jitter at the boundary.
  static const int stickEnter = 18000;
  static const int stickExit = 12000;

  // Discrete (edge-detected) buttons, keyed by their frame bitmask. D-pad is
  // intentionally excluded — it drives the repeating directional channel.
  static const Map<int, GamepadButton> buttonBits = <int, GamepadButton>{
    GamepadFrameBits.a: GamepadButton.a,
    GamepadFrameBits.b: GamepadButton.b,
    GamepadFrameBits.x: GamepadButton.x,
    GamepadFrameBits.y: GamepadButton.y,
    GamepadFrameBits.leftShoulder: GamepadButton.lb,
    GamepadFrameBits.rightShoulder: GamepadButton.rb,
    GamepadFrameBits.start: GamepadButton.start,
    GamepadFrameBits.back: GamepadButton.select,
    GamepadFrameBits.leftThumb: GamepadButton.thumbLeft,
    GamepadFrameBits.rightThumb: GamepadButton.thumbRight,
  };

  int _prevButtons = 0;
  bool _prevLeftTrigger = false;
  bool _prevRightTrigger = false;

  // A-button hold state (only used when [onLongPress] is set). _aDownMs is the
  // frame timestamp A went down (0 = up); _aLongFired guards one long-press per
  // hold and suppresses the release-activate.
  int _aDownMs = 0;
  bool _aLongFired = false;

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
    _aDownMs = 0;
    _aLongFired = false;
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
    // Edge-detected discrete buttons. A is handled separately below when
    // long-press is supported (decided on release), so skip it here to avoid a
    // double-fire.
    for (final MapEntry<int, GamepadButton> entry in buttonBits.entries) {
      if (onLongPress != null && entry.value == GamepadButton.a) continue;
      final int mask = entry.key;
      final bool down = (buttons & mask) != 0;
      final bool wasDown = (_prevButtons & mask) != 0;
      if (down && !wasDown) onButton(entry.value);
    }

    // A: mirror a mouse's tap-vs-long-press. Decide on RELEASE — a release
    // before [longPressMs] is an activate (onButton A); holding past it emits
    // one long-press (onLongPress A) and suppresses the activate. Skipped
    // entirely when long-press is unsupported (A then fired on the press edge
    // by the loop above).
    if (onLongPress != null) {
      final bool aDown = (buttons & GamepadFrameBits.a) != 0;
      final bool aWas = (_prevButtons & GamepadFrameBits.a) != 0;
      if (aDown && !aWas) {
        _aDownMs = nowMs;
        _aLongFired = false;
      } else if (aDown && aWas) {
        if (!_aLongFired && nowMs - _aDownMs >= longPressMs) {
          _aLongFired = true;
          onLongPress!(GamepadButton.a);
        }
      } else if (!aDown && aWas) {
        if (!_aLongFired) onButton(GamepadButton.a);
        _aDownMs = 0;
      }
    }

    // Triggers behave as digital buttons past the standard threshold.
    final bool lt = leftTrigger > GamepadFrameBits.triggerThreshold;
    if (lt && !_prevLeftTrigger) onButton(GamepadButton.lt);
    _prevLeftTrigger = lt;
    final bool rt = rightTrigger > GamepadFrameBits.triggerThreshold;
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
    if ((buttons & GamepadFrameBits.dpadUp) != 0) return TraversalDirection.up;
    if ((buttons & GamepadFrameBits.dpadDown) != 0) {
      return TraversalDirection.down;
    }
    if ((buttons & GamepadFrameBits.dpadLeft) != 0) {
      return TraversalDirection.left;
    }
    if ((buttons & GamepadFrameBits.dpadRight) != 0) {
      return TraversalDirection.right;
    }
    return null;
  }

  /// Hysteretic left-stick → direction. Up is +Y.
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

/// Mutable controller "frame" state, folded from `gamepads` normalized events.
///
/// Pure + unit-testable (no plugin/stream/timer): maps the plugin's normalized
/// buttons/axes into the [GamepadFrameBits] bitmask + stick/trigger values that
/// [GamepadFrameProcessor] consumes. Buttons set/clear a bit on press/release;
/// the stick and triggers are scaled into the frame's integer ranges.
class GamepadFrameState {
  int buttons = 0; // frame bitmask, rebuilt from button down/up events
  int leftTrigger = 0; // 0..GamepadFrameBits.triggerMax
  int rightTrigger = 0;
  int stickX = 0; // -axisMax..axisMax
  int stickY = 0;

  // Normalized gamepads button -> frame bitmask (only the directional/face/
  // shoulder/thumb/menu buttons the processor understands; home/touchpad are
  // ignored, triggers are handled as analog axes below).
  static const Map<gp.GamepadButton, int> _bitFor = <gp.GamepadButton, int>{
    gp.GamepadButton.a: GamepadFrameBits.a,
    gp.GamepadButton.b: GamepadFrameBits.b,
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

  void applyButton(gp.GamepadButton button, double value) {
    final int? bit = _bitFor[button];
    if (bit != null) {
      if (value >= 0.5) {
        buttons |= bit;
      } else {
        buttons &= ~bit;
      }
    } else if (button == gp.GamepadButton.leftTrigger) {
      leftTrigger = value >= 0.5 ? GamepadFrameBits.triggerMax : 0;
    } else if (button == gp.GamepadButton.rightTrigger) {
      rightTrigger = value >= 0.5 ? GamepadFrameBits.triggerMax : 0;
    }
  }

  void applyAxis(gp.GamepadAxis axis, double value) {
    if (axis == gp.GamepadAxis.leftStickX) {
      stickX = (value * GamepadFrameBits.axisMax).round();
    } else if (axis == gp.GamepadAxis.leftStickY) {
      stickY = (value * GamepadFrameBits.axisMax).round();
    } else if (axis == gp.GamepadAxis.leftTrigger) {
      leftTrigger = (value * GamepadFrameBits.triggerMax).round();
    } else if (axis == gp.GamepadAxis.rightTrigger) {
      rightTrigger = (value * GamepadFrameBits.triggerMax).round();
    }
  }
}

/// Subscribes to the `gamepads` plugin's normalized event stream and folds it
/// into a [GamepadFrameState], then feeds [GamepadFrameProcessor] on a fixed
/// tick — so edge detection, stick dead-zone/hysteresis and auto-repeat behave
/// identically on every polled platform.
class _PluginGamepadPoller {
  _PluginGamepadPoller({required this.processor});

  final GamepadFrameProcessor processor;

  static const Duration _pollInterval = Duration(milliseconds: 60);

  StreamSubscription<gp.NormalizedGamepadEvent>? _sub;
  Timer? _timer;
  // Monotonic clock for auto-repeat timing — immune to wall-clock/NTP/DST jumps.
  final Stopwatch _clock = Stopwatch()..start();
  final GamepadFrameState _state = GamepadFrameState();

  void start() {
    try {
      _sub ??= gp.Gamepads.normalizedEvents.listen(
        _onEvent,
        // Stream errors arrive asynchronously (a backend faulting at runtime);
        // log rather than letting them surface as unhandled.
        onError: (Object e) =>
            debugPrint('[gamepad] gamepads stream error: $e'),
      );
    } catch (e) {
      debugPrint('[gamepad] gamepads plugin unavailable: $e');
      return;
    }
    _timer ??= Timer.periodic(_pollInterval, (_) {
      processor.processFrame(
        buttons: _state.buttons,
        leftTrigger: _state.leftTrigger,
        rightTrigger: _state.rightTrigger,
        stickX: _state.stickX,
        stickY: _state.stickY,
        nowMs: _clock.elapsedMilliseconds,
      );
    });
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
  }

  void _onEvent(gp.NormalizedGamepadEvent e) {
    final gp.GamepadButton? button = e.button;
    if (button != null) {
      _state.applyButton(button, e.value);
      return;
    }
    final gp.GamepadAxis? axis = e.axis;
    if (axis != null) _state.applyAxis(axis, e.value);
  }
}
