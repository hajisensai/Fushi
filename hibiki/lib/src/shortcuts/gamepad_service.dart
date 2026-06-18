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
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';
import 'package:hibiki/src/focus/page_scroll_registry.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

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

/// Dispatches a normalized gamepad [button] to the [GamepadButtonIntent]
/// handler nearest [context]. Returns true only when a focused page/widget
/// explicitly consumes the button.
bool dispatchGamepadButtonIntent(
  BuildContext context,
  GamepadButton button,
) {
  return Actions.maybeInvoke<GamepadButtonIntent>(
        context,
        GamepadButtonIntent(button),
      ) ==
      true;
}

/// Converts Android/native controller key events into the same focused
/// [GamepadButtonIntent] path used by the desktop poller. B is deliberately
/// ignored here so existing global-back shortcuts remain the fallback owner.
KeyEventResult dispatchNativeGamepadButtonIntent(KeyEvent event) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  final GamepadButton? button = GamepadButton.fromKeyEvent(event);
  if (button == null || button == GamepadButton.b) {
    return KeyEventResult.ignored;
  }

  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return KeyEventResult.ignored;
  return dispatchGamepadButtonIntent(context, button)
      ? KeyEventResult.handled
      : KeyEventResult.ignored;
}

/// Wraps a focusable widget so a gamepad long-press (hold A) invokes the SAME
/// [onLongPress] callback a mouse long-press would. Place it ABOVE the widget
/// that takes focus (e.g. around a focusable list tile) so the
/// [GamepadLongPressIntent] dispatched to the focused node bubbles here. A null
/// [onLongPress] is a transparent pass-through.
class GamepadLongPressActions extends StatefulWidget {
  const GamepadLongPressActions({
    required this.onLongPress,
    required this.child,
    super.key,
  });

  final VoidCallback? onLongPress;
  final Widget child;

  @override
  State<GamepadLongPressActions> createState() =>
      _GamepadLongPressActionsState();
}

class _GamepadLongPressActionsState extends State<GamepadLongPressActions> {
  Timer? _aHoldTimer;
  bool _aLongFired = false;

  @override
  void dispose() {
    _clearAHold();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onLongPress == null) return widget.child;
    return Actions(
      actions: <Type, Action<Intent>>{
        GamepadLongPressIntent: CallbackAction<GamepadLongPressIntent>(
          onInvoke: (GamepadLongPressIntent intent) {
            if (intent.button != GamepadButton.a) return false;
            widget.onLongPress!();
            return true; // handled → GamepadService skips its activate fallback
          },
        ),
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _handleNativeGamepadKey,
        child: widget.child,
      ),
    );
  }

  KeyEventResult _handleNativeGamepadKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.gameButtonA) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      if (_aHoldTimer != null) return KeyEventResult.handled;
      _aLongFired = false;
      _aHoldTimer = Timer(
        const Duration(milliseconds: GamepadFrameProcessor.longPressMs),
        () {
          _aHoldTimer = null;
          _aLongFired = true;
          if (mounted) widget.onLongPress?.call();
        },
      );
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      final bool longFired = _aLongFired;
      _clearAHold();
      if (!longFired) {
        final BuildContext targetContext =
            FocusManager.instance.primaryFocus?.context ?? context;
        Actions.maybeInvoke<ActivateIntent>(
          targetContext,
          const ActivateIntent(),
        );
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _clearAHold() {
    _aHoldTimer?.cancel();
    _aHoldTimer = null;
    _aLongFired = false;
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
  GamepadService({required this.navigatorKey, this.registry});

  final GlobalKey<NavigatorState> navigatorKey;

  /// Resolves which action a controller button is bound to, used by the global
  /// LB/RB scroll-page fallback so a user-rebound key still works. Null in tests
  /// that don't exercise scrolling.
  final HibikiShortcutRegistry? registry;

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
    // Start with the ring HIDDEN: it must only appear AFTER the user actually
    // drives with a controller or physical keyboard ("焦点应该在使用手柄或者键盘
    // 以后才会出来"). Desktop's default `automatic` strategy treats a mouse as
    // "traditional" and shows the ring from launch / during mouse use, which is
    // exactly what we don't want — so we own the strategy explicitly here and in
    // the pointer/key handlers below. Android (service no-op) keeps Flutter's
    // automatic strategy, which already starts in touch mode on touch devices.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
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

    // The page didn't consume the button: LB/RB (or whatever the user bound to
    // the global scroll-page actions) page-scrolls the current page's primary
    // scroll view. This is the only path that scrolls a pure-display page
    // (statistics/logs) which has no focus geometry for D-pad edge takeover.
    if (_tryScrollPage(ctx, button)) return;

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

  /// LB/RB page-scroll fallback: if [button] is bound to a global scroll-page
  /// action, page the nearest [PrimaryScrollController] by ~0.9 viewport.
  /// Returns whether it scrolled (so the dispatcher can stop).
  bool _tryScrollPage(BuildContext context, GamepadButton button) {
    final ShortcutAction? action =
        registry?.resolveGamepad(button, scope: ShortcutScope.global);
    final double fraction;
    if (action == ShortcutAction.globalScrollPageDown) {
      fraction = 0.9;
    } else if (action == ShortcutAction.globalScrollPageUp) {
      fraction = -0.9;
    } else {
      return false;
    }
    // Prefer the registered active-page controller. On a pure-display page
    // (statistics/logs) focus is the top-level fallback node, which sits ABOVE
    // the page scaffold's PrimaryScrollController, so a context lookup from
    // focus can never reach it. Fall back to a context lookup for pages not
    // built on HibikiPageScaffold (e.g. home tab content, focus inside list).
    final ScrollController? pageController = PageScrollRegistry.current;
    if (pageController != null &&
        HibikiFocusScroll.scrollController(pageController, fraction)) {
      return true;
    }
    return HibikiFocusScroll.scrollPrimary(context, fraction);
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

/// Maps a [TraversalDirection] to the [AxisDirection] of the scroll it would
/// drive, so edge-takeover scrolling only fires on the matching axis (a
/// left/right press never scrolls a vertical list, and vice versa).
AxisDirection axisDirectionFromTraversal(TraversalDirection direction) {
  switch (direction) {
    case TraversalDirection.up:
      return AxisDirection.up;
    case TraversalDirection.down:
      return AxisDirection.down;
    case TraversalDirection.left:
      return AxisDirection.left;
    case TraversalDirection.right:
      return AxisDirection.right;
  }
}

/// Maps a keyboard arrow key to the [TraversalDirection] it drives for focus
/// navigation; any non-arrow key returns null. Shared by the home page handler
/// and the app-wide [wrapWithGlobalNavigation] handler so both read arrows the
/// same way.
TraversalDirection? arrowTraversalDirection(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowUp) return TraversalDirection.up;
  if (key == LogicalKeyboardKey.arrowDown) return TraversalDirection.down;
  if (key == LogicalKeyboardKey.arrowLeft) return TraversalDirection.left;
  if (key == LogicalKeyboardKey.arrowRight) return TraversalDirection.right;
  return null;
}

/// Whether [event] is a keyboard event that should drive a single step of
/// directional FOCUS movement — i.e. an arrow key on its press edge
/// ([KeyDownEvent]) OR an OS auto-repeat ([KeyRepeatEvent]).
///
/// Holding an arrow key makes the OS emit one [KeyDownEvent] followed by a
/// stream of [KeyRepeatEvent]s until release; treating BOTH as a move keeps
/// focus advancing continuously while held instead of one step per discrete
/// press (“一个字一个字按过去还是太吃手指”). [KeyUpEvent] is excluded so release
/// does not move. Returns the [TraversalDirection] for the key, or null when the
/// event/key should not move focus (non-arrow key, or a [KeyUpEvent]).
///
/// Both [event] type and the arrow→direction mapping are centralized here so the
/// home page handler and the app-wide wrapper agree on exactly which keyboard
/// events continuously move focus — the move itself stays the caller's
/// [gamepadMoveFocusInDirection], so KeyDown and KeyRepeat share one geometry/
/// reading-order path (the framework's bare DirectionalFocusAction does NOT
/// carry Hibiki's reading-order fallback, so relying on it for repeats would
/// dead-end at row/panel edges where the press edge advanced fine).
TraversalDirection? arrowFocusMoveDirection(KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
  return arrowTraversalDirection(event.logicalKey);
}

/// The [EditableText] that currently holds focus, or null when no text field is
/// focused. Lets callers decide per-direction whether an arrow key should drive
/// the text caret or move focus (single-line fields don't use up/down).
///
/// [EditableText] owns its focus through an inner `Focus(debugLabel:
/// 'EditableText')`, so the primary focus node's own `context.widget` is that
/// `Focus`, NOT the [EditableText] — a bare `is EditableText` check would always
/// miss. The [EditableText] is that Focus's ancestor element, so we look it up.
EditableText? focusedEditableText() {
  final BuildContext? c = FocusManager.instance.primaryFocus?.context;
  if (c == null) return null;
  if (c.widget is EditableText) return c.widget as EditableText;
  return c.findAncestorWidgetOfExactType<EditableText>();
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
///
/// With a Hibiki focus root, controller failure only falls through to
/// directional geometry. Reading-order fallback stays disabled there so a
/// shelf edge can escape to the side rail or top bar without sliding sideways
/// through shelf items.
///
/// Returns whether focus actually changed.
bool gamepadMoveFocusInDirection(
  BuildContext context,
  TraversalDirection direction,
) {
  final HibikiFocusController? controller =
      HibikiFocusRoot.maybeControllerOf(context);
  if (controller != null) {
    if (controller.move(hibikiFocusDirectionFromTraversal(direction))) {
      return true;
    }
    // No registered target in this direction: take over and scroll the focused
    // control's nearest scrollable by a screen-fraction, so a long list/page
    // does not dead-end at its last focusable. Axis-matched so a left/right
    // press never scrolls a vertical list. At the scroll extent this returns
    // false and the press falls through to the (disabled) reading-order
    // fallback — i.e. it simply stops at the edge.
    final BuildContext? focusContext =
        controller.activeContext ?? FocusManager.instance.primaryFocus?.context;
    if (controller.activeIsOnlyFocusableInNearestScrollable &&
        focusContext != null &&
        HibikiFocusScroll.scrollByViewportFraction(
          focusContext,
          axisDirectionFromTraversal(direction),
          HibikiFocusScroll.signedFractionFor(direction, 0.8),
        )) {
      return true;
    }
    return _movePrimaryFocusInDirection(
      context,
      direction,
      allowReadingOrderFallback: false,
    );
  }

  return _movePrimaryFocusInDirection(
    context,
    direction,
    allowReadingOrderFallback: true,
  );
}

bool _movePrimaryFocusInDirection(
  BuildContext context,
  TraversalDirection direction, {
  required bool allowReadingOrderFallback,
}) {
  final FocusNode? primary = FocusManager.instance.primaryFocus;
  // Bootstrap when nothing is usefully focused: null, a scope, a non-focusable
  // node, or a skip-traversal wrapper (e.g. a full-page key-event sink — moving
  // "in a direction" from its whole-screen rect is meaningless, so jump to the
  // first real control instead).
  if (primary == null ||
      primary is FocusScopeNode ||
      !primary.canRequestFocus ||
      primary.skipTraversal) {
    return allowReadingOrderFallback && FocusScope.of(context).nextFocus();
  }
  if (primary.focusInDirection(direction)) return true;
  if (!allowReadingOrderFallback) return false;
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
