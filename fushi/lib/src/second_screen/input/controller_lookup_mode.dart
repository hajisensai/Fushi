import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TraversalDirection;
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/input/controller_lookup_target.dart';
import 'package:fushi/src/shortcuts/dictionary_popup_gamepad.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';

/// The one controller lookup mode shared by reader, video, manga and music
/// (S6 of the dual-screen companion).
///
/// It sits in front of page dispatch (the desktop poller path in
/// `GamepadService._dispatchButton`, a `FocusManager` early key handler for
/// Android's controller key events): [onPress] / [onRelease] return true when
/// the button was consumed and the page must not see it.
///
/// **Lookup mode** (needs an attached, available [ControllerLookupTarget]):
/// hold L1 (navigation live while held; a short L1 tap is replayed on release
/// so the page's normal L1 binding still works) or Select toggles, per
/// [ControllerLookupStyle]. While active:
///
/// * D-pad / left stick left/right: step by word (character when the page has
///   no word steps, or after Y switched to character granularity);
/// * D-pad / left stick up/down: previous / next line;
/// * A: look up; A again while a lookup is open: mine;
/// * X: word audio; R2 / L2: next / previous entry; right stick: scroll;
/// * B: close the lookup, then leave the mode.
///
/// The lookup goes to the companion's Lookup tab while the companion is up
/// ([CompanionContextRegistry.controller]) and to the page's in-page popup
/// otherwise (the page's own lookup path decides; the mode only routes the
/// follow-up buttons to the same place).
///
/// **Panel drive** (independent of lookup mode, companion up only): while R1 is
/// held, D-pad / left stick / A / B drive the companion's own focus
/// ([CompanionPanelNav]); every other button is swallowed. A short R1 tap with
/// no panel input is replayed on release. Released → the controller drives the
/// top screen again. Main-engine focus never moves: the top page keeps its
/// Flutter focus the whole time, the panel's engine moves its own.
class ControllerLookupMode extends ChangeNotifier {
  ControllerLookupMode({CompanionContextRegistry? registry})
    : _registry = registry ?? companionContexts;

  static final ControllerLookupMode instance = ControllerLookupMode();

  /// Key repeat of a held D-pad direction (the mode runs its own; OS repeats
  /// are swallowed, see [swallowsRepeat]).
  static const Duration repeatDelay = Duration(milliseconds: 400);
  static const Duration repeatInterval = Duration(milliseconds: 150);

  /// Holding L1 this long (with no other input) enters the mode; a release
  /// before it with no other input counts as a tap.
  static const Duration holdThreshold = Duration(milliseconds: 250);

  final CompanionContextRegistry _registry;
  ControllerLookupTarget? _target;

  /// Replays a tapped L1 / R1 (and B for the in-page popup's own close path)
  /// through the normal dispatch; set by `GamepadService`.
  void Function(GamepadButton button)? redispatch;

  /// Test seam for the in-page popup hooks.
  @visibleForTesting
  DictionaryPopupGamepadHooks? Function() popupHooks = () =>
      DictionaryPopupGamepadRegistry.current;

  bool _active = false;
  bool _wordGranularity = true;

  bool _lbHeld = false;
  bool _lbUsed = false;
  Timer? _lbTimer;

  bool _rbHeld = false;
  bool _rbUsed = false;
  bool _panelBegun = false;

  GamepadButton? _repeating;
  Timer? _repeatTimer;

  /// Lookup mode is on (the badge shows).
  bool get active => _active;

  /// Left / right step by word (true) or by character.
  bool get wordGranularity => _wordGranularity;

  /// R1 is held and drives the companion's focus.
  bool get panelDriving => _rbHeld;

  ControllerLookupTarget? get target => _target;

  CompanionControllerSink? get _companion => _registry.controller;

  ControllerLookupTarget? get _availableTarget {
    final ControllerLookupTarget? t = _target;
    return t != null && t.isAvailable ? t : null;
  }

  ControllerLookupStyle get style => ControllerLookupStyle.resolve(
    _target?.readPref(kControllerLookupStylePrefKey),
    companionActive: _companion != null,
  );

  /// A page claims the mode while it is on screen. A later claim replaces an
  /// earlier one; [detach] only clears its own.
  void attach(ControllerLookupTarget target) {
    if (!identical(_target, target)) _reset(notify: true);
    _target = target;
  }

  void detach(ControllerLookupTarget target) {
    if (!identical(_target, target)) return;
    _reset(notify: true);
    _target = null;
  }

  bool get _lookupOpen {
    final CompanionControllerSink? c = _companion;
    if (c != null) return c.lookupOpen;
    return popupHooks()?.hasVisiblePopup() ?? false;
  }

  // ---- input ----

  /// A button went down. True = consumed (the page must not see it).
  bool onPress(GamepadButton button) {
    // Panel drive (R1 held, companion up).
    if (_rbHeld) {
      if (_isPanelButton(button)) {
        _rbUsed = true;
        _beginPanel();
        _startRepeat(
          button,
          repeats: button.isDpad,
          action: () => _panelNav(_panelNavOf(button)),
        );
      }
      return true; // everything else is swallowed while panel-driving
    }
    if (button == GamepadButton.rb && _companion != null) {
      _rbHeld = true;
      _rbUsed = false;
      _panelBegun = false;
      return true;
    }

    final ControllerLookupTarget? t = _availableTarget;
    if (t == null) {
      if (_active || _lbHeld) _reset(notify: true);
      return false;
    }

    final ControllerLookupStyle s = style;
    if (s == ControllerLookupStyle.holdL1 && button == GamepadButton.lb) {
      if (_lbHeld) return true; // OS key repeat
      _lbHeld = true;
      _lbUsed = false;
      _lbTimer?.cancel();
      _lbTimer = Timer(holdThreshold, () {
        if (_lbHeld && !_active) _setActive(true);
      });
      return true;
    }
    if (s == ControllerLookupStyle.selectToggle &&
        button == GamepadButton.select) {
      _setActive(!_active);
      return true;
    }

    if (_lbHeld && !_active && !_lbUsed && _isModeButton(button)) {
      // First lookup input during the hold: enter right away.
      _setActive(true);
    }
    if (_lbHeld && !_active) return true; // mode left via B: swallow the rest
    if (!_active) return false;
    if (_lbHeld) _lbUsed = true;
    if (!t.routerOwnsInput) return false;
    return _handleActive(t, button);
  }

  /// A button went up. True = consumed.
  bool onRelease(GamepadButton button) {
    if (_repeating == button) _stopRepeat();
    if (button == GamepadButton.lb && _lbHeld) {
      final bool wasActive = _active;
      final bool used = _lbUsed;
      _lbHeld = false;
      _lbTimer?.cancel();
      if (wasActive) _setActive(false);
      if (!wasActive && !used) redispatch?.call(GamepadButton.lb);
      return true;
    }
    if (button == GamepadButton.rb && _rbHeld) {
      final bool used = _rbUsed;
      _rbHeld = false;
      _stopRepeat();
      if (_panelBegun) {
        _panelBegun = false;
        _panelNav(CompanionPanelNav.end);
      }
      if (!used) redispatch?.call(GamepadButton.rb);
      return true;
    }
    if (_rbHeld) return true;
    return _active && _isModeButton(button);
  }

  /// Left stick moved one step in [direction] (desktop poller). True =
  /// consumed (panel drive or lookup mode).
  bool onStickMove(TraversalDirection direction) {
    final GamepadButton dpad = switch (direction) {
      TraversalDirection.up => GamepadButton.dpadUp,
      TraversalDirection.down => GamepadButton.dpadDown,
      TraversalDirection.left => GamepadButton.dpadLeft,
      TraversalDirection.right => GamepadButton.dpadRight,
    };
    if (_rbHeld) {
      _rbUsed = true;
      _beginPanel();
      _panelNav(_panelNavOf(dpad));
      return true;
    }
    final ControllerLookupTarget? t = _availableTarget;
    if (!_active || t == null || !t.routerOwnsInput) return false;
    if (_lbHeld) _lbUsed = true;
    _stepFor(t, dpad);
    return true;
  }

  /// Right stick vertical scroll amount in logical pixels (positive = down).
  /// True = consumed.
  bool onRightStick(double dy) {
    if (!_active || !_lookupOpen) return false;
    final CompanionControllerSink? c = _companion;
    if (c != null) {
      c.sendLookupAction(CompanionLookupActions.scroll, <String, Object?>{
        CompanionLookupActions.dy: dy,
      });
    } else {
      unawaited(popupHooks()?.scrollBy(dy) ?? Future<void>.value());
    }
    return true;
  }

  /// OS key-repeat of a held button (Android): swallowed while the mode owns
  /// it (the mode runs its own 400 ms / 150 ms repeat).
  bool swallowsRepeat(GamepadButton button) =>
      (button == GamepadButton.lb && _lbHeld) ||
      _rbHeld ||
      ((_active || _lbHeld) && _isModeButton(button));

  bool _isPanelButton(GamepadButton b) =>
      b.isDpad || b == GamepadButton.a || b == GamepadButton.b;

  bool _isModeButton(GamepadButton b) =>
      b.isDpad ||
      b == GamepadButton.a ||
      b == GamepadButton.b ||
      b == GamepadButton.x ||
      b == GamepadButton.y ||
      b == GamepadButton.lt ||
      b == GamepadButton.rt;

  static String _panelNavOf(GamepadButton b) => switch (b) {
    GamepadButton.dpadUp => CompanionPanelNav.up,
    GamepadButton.dpadDown => CompanionPanelNav.down,
    GamepadButton.dpadLeft => CompanionPanelNav.left,
    GamepadButton.dpadRight => CompanionPanelNav.right,
    GamepadButton.a => CompanionPanelNav.activate,
    _ => CompanionPanelNav.back,
  };

  void _panelNav(String action) => _companion?.sendPanelNav(action);

  void _beginPanel() {
    if (_panelBegun) return;
    _panelBegun = true;
    _panelNav(CompanionPanelNav.begin);
  }

  bool _handleActive(ControllerLookupTarget t, GamepadButton button) {
    switch (button) {
      case GamepadButton.dpadLeft:
      case GamepadButton.dpadRight:
      case GamepadButton.dpadUp:
      case GamepadButton.dpadDown:
        _startRepeat(button, repeats: true, action: () => _stepFor(t, button));
        return true;
      case GamepadButton.a:
        if (_lookupOpen) {
          _lookupAction(CompanionLookupActions.mine);
        } else {
          unawaited(t.lookupAtCursor());
        }
        return true;
      case GamepadButton.x:
        _lookupAction(CompanionLookupActions.playAudio);
        return true;
      case GamepadButton.y:
        _wordGranularity = !_wordGranularity;
        notifyListeners();
        return true;
      case GamepadButton.rt:
        _lookupAction(CompanionLookupActions.nextEntry);
        return true;
      case GamepadButton.lt:
        _lookupAction(CompanionLookupActions.prevEntry);
        return true;
      case GamepadButton.b:
        if (_lookupOpen) {
          _closeLookup();
        } else {
          if (_lbHeld) _lbUsed = true;
          _setActive(false);
        }
        return true;
      default:
        return false;
    }
  }

  void _stepFor(ControllerLookupTarget t, GamepadButton dpad) {
    switch (dpad) {
      case GamepadButton.dpadLeft:
      case GamepadButton.dpadRight:
        final int dir = dpad == GamepadButton.dpadRight ? 1 : -1;
        unawaited(t.stepCursor(dir, word: _wordGranularity && t.hasWordSteps));
      case GamepadButton.dpadUp:
      case GamepadButton.dpadDown:
        unawaited(t.stepLine(dpad == GamepadButton.dpadDown ? 1 : -1));
      default:
        break;
    }
  }

  /// Mine / audio / entry moves go to the companion's lookup when it is up,
  /// else to the visible in-page popup.
  void _lookupAction(String action) {
    final CompanionControllerSink? c = _companion;
    if (c != null) {
      c.sendLookupAction(action);
      return;
    }
    final DictionaryPopupGamepadHooks? hooks = popupHooks();
    if (hooks == null) return;
    final Future<void> pending = switch (action) {
      CompanionLookupActions.mine => hooks.mineFirstEntry(),
      CompanionLookupActions.playAudio => hooks.playFirstAudio(),
      CompanionLookupActions.nextEntry => hooks.entryMove(true),
      CompanionLookupActions.prevEntry => hooks.entryMove(false),
      _ => Future<void>.value(),
    };
    unawaited(pending);
  }

  void _closeLookup() {
    final CompanionControllerSink? c = _companion;
    if (c != null) {
      c.sendLookupAction(CompanionLookupActions.close);
    } else {
      // The page's own popup close path (universal Back closes the popup
      // before anything else), so hand B to the page.
      redispatch?.call(GamepadButton.b);
    }
  }

  // ---- repeat (400 ms, then every 150 ms) ----

  void _startRepeat(
    GamepadButton button, {
    required bool repeats,
    required VoidCallback action,
  }) {
    if (_repeating == button) return; // processor / OS repeat of a held key
    _stopRepeat();
    action();
    if (!repeats) return;
    _repeating = button;
    _repeatTimer = Timer(repeatDelay, () {
      _repeatTimer = Timer.periodic(repeatInterval, (_) => action());
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _repeating = null;
  }

  // ---- state ----

  void _setActive(bool value) {
    if (_active == value) return;
    _active = value;
    _lbTimer?.cancel();
    _stopRepeat();
    final ControllerLookupTarget? t = _target;
    if (value) {
      t?.onModeEntered();
    } else {
      t?.onModeExited();
    }
    notifyListeners();
  }

  void _reset({required bool notify}) {
    _lbTimer?.cancel();
    _stopRepeat();
    final bool was = _active;
    if (was) _target?.onModeExited();
    _active = false;
    _lbHeld = false;
    if (_panelBegun) _panelNav(CompanionPanelNav.end);
    _rbHeld = false;
    _panelBegun = false;
    if (was && notify) notifyListeners();
  }

  @visibleForTesting
  void debugReset() {
    _reset(notify: false);
    _target = null;
    redispatch = null;
    _wordGranularity = true;
    popupHooks = () => DictionaryPopupGamepadRegistry.current;
  }
}
