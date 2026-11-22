import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TraversalDirection;
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/input/controller_lookup_target.dart';
import 'package:fushi/src/shortcuts/dictionary_popup_gamepad.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// The one controller lookup mode shared by reader, video, manga and music
/// (S6 of the dual-screen companion; the only controller lookup since the
/// 2026-11-22 unification,
/// docs/specs/2026-11-22-gamepad-lookup-unification-design.md).
///
/// It sits in front of page dispatch (the desktop poller path in
/// `GamepadService._dispatchButton`, a `FocusManager` early key handler for
/// Android's controller key events): [onPress] / [onRelease] return true when
/// the button was consumed and the page must not see it.
///
/// **Lookup mode** (needs an attached, available [ControllerLookupTarget]):
/// hold L1 (navigation live while held; a short L1 tap is replayed on release
/// so the page's normal L1 binding still works) or Select toggles, per
/// [ControllerLookupStyle] (default hold L1). Entering is not a shortcut: the
/// preference decides it. While active every button is resolved against the
/// [ShortcutScope.controllerLookup] bindings of [shortcutRegistry] (all
/// remappable; defaults in `ShortcutDefaults`):
///
/// * cursor left / right (D-pad ←/→): step by word (character when the page has
///   no word steps, or after the granularity toggle, L3);
/// * line up / down (D-pad ↑/↓): previous / next line;
/// * **look up when the cursor stops**: a single step looks up at once; while a
///   held direction repeats nothing is looked up, the release looks up once;
/// * selection right end −1 / +1 grapheme (right stick ←/→): caps the lookup
///   ([ControllerLookupTarget.lookupAtCursor]'s `maxGraphemes`) and looks up
///   again; any cursor move clears the cap;
/// * mine (X), word audio (Y), next / previous entry (RT / LT); the right
///   stick's vertical axis scrolls the result (analog, not remappable);
/// * enter result (A): hands the cursor to the page's in-page popup cursor;
/// * close or exit (B): close the lookup, then leave the mode.
///
/// The left stick is a fixed alias of the four cursor moves (not remappable).
///
/// The lookup goes to the companion's Lookup tab while the companion is up
/// and the user wants lookups there ([CompanionContextRegistry.lookupController])
/// and to the page's in-page popup otherwise (the page's own lookup path
/// decides; the mode only routes the follow-up buttons to the same place).
///
/// **Panel drive** (independent of lookup mode, companion up only): while R1 is
/// held, D-pad / left stick / A / B drive the companion's own focus
/// ([CompanionPanelNav]); every other button is swallowed. A short R1 tap with
/// no panel input is replayed on release. Released → the controller drives the
/// top screen again. Main-engine focus never moves: the top page keeps its
/// Flutter focus the whole time, the panel's engine moves its own.
class ControllerLookupMode extends ChangeNotifier {
  ControllerLookupMode({
    CompanionContextRegistry? registry,
    this.shortcutRegistry,
  }) : _registry = registry ?? companionContexts;

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

  /// Where the mode's buttons are looked up ([ShortcutScope.controllerLookup]);
  /// set by `GamepadService.start` to the app's registry. Null = no button is a
  /// lookup-mode button (the mode then only enters and leaves).
  FushiShortcutRegistry? shortcutRegistry;

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

  /// Runs when the held [_repeating] button is released after at least one
  /// repeat fired (the "look up once the cursor stops" half of a held move).
  VoidCallback? _onRepeatEnd;
  bool _repeated = false;

  /// Selection right-end cap in graphemes (null = unlimited, the dictionary's
  /// longest match). Any cursor / line move clears it.
  int? _maxGraphemes;

  /// Highlight length of the last finished lookup (null = none / nothing
  /// matched). Cleared by any cursor / line move.
  int? _lastMatched;

  /// The last cursor / line step still running; a lookup waits for it so it
  /// reads the cursor where the step put it.
  Future<void>? _pendingStep;

  /// Bumped per lookup and on reset: a finished lookup only records its match
  /// length when no later lookup started meanwhile.
  int _lookupSeq = 0;

  /// The left stick is mid-push in lookup mode; [_stickMoved] = it stepped
  /// again after the lookup of its first step.
  bool _stickBurst = false;
  bool _stickMoved = false;

  /// Lookup mode is on (the badge shows).
  bool get active => _active;

  /// Left / right step by word (true) or by character.
  bool get wordGranularity => _wordGranularity;

  /// R1 is held and drives the companion's focus.
  bool get panelDriving => _rbHeld;

  ControllerLookupTarget? get target => _target;

  /// Selection right-end cap of the next lookup (null = unlimited).
  int? get maxGraphemes => _maxGraphemes;

  /// Highlight length of the last finished lookup (null = none).
  int? get lastMatched => _lastMatched;

  /// The companion while it is up (R1 panel drive).
  CompanionControllerSink? get _companion => _registry.controller;

  /// The companion when lookups open there; null when it is down or the user
  /// wants lookups on the main screen ("Lookups open on: Top screen"), so the
  /// follow-up buttons drive the in-page popup.
  CompanionControllerSink? get _companionLookup => _registry.lookupController;

  ControllerLookupTarget? get _availableTarget {
    final ControllerLookupTarget? t = _target;
    return t != null && t.isAvailable ? t : null;
  }

  ControllerLookupStyle get style => ControllerLookupStyle.resolve(
    _target?.readPref(kControllerLookupStylePrefKey),
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

  Object? _rawInputOwner;

  /// A page that forwards the raw controller (the game stream sends every
  /// button, L1 / R1 included, to the remote game) claims it while it is on
  /// screen: neither lookup mode nor R1 panel drive may take a button then,
  /// even when the companion is up. A later claim replaces an earlier one;
  /// [releaseRawInput] only clears its own.
  void claimRawInput(Object owner) {
    _reset(notify: true);
    _rawInputOwner = owner;
  }

  void releaseRawInput(Object owner) {
    if (identical(_rawInputOwner, owner)) _rawInputOwner = null;
  }

  /// A page owns the raw controller ([claimRawInput]).
  bool get rawInputClaimed => _rawInputOwner != null;

  bool get _lookupOpen {
    final CompanionControllerSink? c = _companionLookup;
    if (c != null) return c.lookupOpen;
    return popupHooks()?.hasVisiblePopup() ?? false;
  }

  // ---- input ----

  /// A button went down. True = consumed (the page must not see it).
  bool onPress(GamepadButton button) {
    if (_rawInputOwner != null) return false;
    // Panel drive (R1 held, companion up).
    if (_rbHeld) {
      if (_isPanelButton(button)) {
        _rbUsed = true;
        _beginPanel();
        _startRepeat(
          button,
          repeats: button.isDpad,
          first: () => _panelNav(_panelNavOf(button)),
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

    final ShortcutAction? action = actionFor(button);
    if (_lbHeld && !_active && !_lbUsed && action != null) {
      // First lookup input during the hold: enter right away.
      _setActive(true);
    }
    if (_lbHeld && !_active) return true; // mode left via B: swallow the rest
    if (!_active) return false;
    if (_lbHeld) _lbUsed = true;
    if (!t.routerOwnsInput) return false;
    if (action == null) return false;
    _runAction(t, button, action);
    return true;
  }

  /// A button went up. True = consumed.
  bool onRelease(GamepadButton button) {
    if (_rawInputOwner != null) return false;
    if (_repeating == button) _endRepeat();
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

  /// Left stick moved one step in [direction] (desktop poller; the poller's
  /// own repeat sends further steps while it is held). True = consumed (panel
  /// drive or lookup mode). The stick is a fixed alias of the four cursor
  /// moves and follows the same "look up when the cursor stops" rule: the
  /// first step of a push looks up at once, a held push looks up once on
  /// [onStickRelease].
  bool onStickMove(TraversalDirection direction) {
    if (_rawInputOwner != null) return false;
    if (_rbHeld) {
      _rbUsed = true;
      _beginPanel();
      _panelNav(_panelNavOf(_dpadOf(direction)));
      return true;
    }
    final ControllerLookupTarget? t = _availableTarget;
    if (!_active || t == null || !t.routerOwnsInput) return false;
    if (_lbHeld) _lbUsed = true;
    final ShortcutAction move = switch (direction) {
      TraversalDirection.up => ShortcutAction.controllerLookupLineUp,
      TraversalDirection.down => ShortcutAction.controllerLookupLineDown,
      TraversalDirection.left => ShortcutAction.controllerLookupCursorLeft,
      TraversalDirection.right => ShortcutAction.controllerLookupCursorRight,
    };
    _move(t, move);
    if (_stickBurst) {
      _stickMoved = true; // held stick: look up once it is released
    } else {
      _stickBurst = true;
      _stickMoved = false;
      unawaited(_lookup(t));
    }
    return true;
  }

  /// The left stick returned to centre (or switched direction) after
  /// [onStickMove] steps: a held push looks up once, here.
  void onStickRelease() {
    if (!_stickBurst) return;
    final bool moved = _stickMoved;
    _stickBurst = false;
    _stickMoved = false;
    final ControllerLookupTarget? t = _availableTarget;
    if (moved && _active && t != null && t.routerOwnsInput) {
      unawaited(_lookup(t));
    }
  }

  /// Right stick vertical scroll amount in logical pixels (positive = down).
  /// True = consumed.
  bool onRightStick(double dy) {
    if (_rawInputOwner != null) return false;
    if (!_active || !_lookupOpen) return false;
    final CompanionControllerSink? c = _companionLookup;
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
      _rawInputOwner == null &&
      ((button == GamepadButton.lb && _lbHeld) ||
          _rbHeld ||
          ((_active || _lbHeld) && _isModeButton(button)));

  /// The [ShortcutScope.controllerLookup] action [button] is bound to in
  /// [shortcutRegistry]; null when unbound (or no registry).
  ShortcutAction? actionFor(GamepadButton button) => shortcutRegistry
      ?.resolveGamepad(button, scope: ShortcutScope.controllerLookup);

  bool _isPanelButton(GamepadButton b) =>
      b.isDpad || b == GamepadButton.a || b == GamepadButton.b;

  bool _isModeButton(GamepadButton b) => actionFor(b) != null;

  static GamepadButton _dpadOf(TraversalDirection direction) =>
      switch (direction) {
        TraversalDirection.up => GamepadButton.dpadUp,
        TraversalDirection.down => GamepadButton.dpadDown,
        TraversalDirection.left => GamepadButton.dpadLeft,
        TraversalDirection.right => GamepadButton.dpadRight,
      };

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

  /// Executes the lookup-mode [action] that [button] resolved to.
  void _runAction(
    ControllerLookupTarget t,
    GamepadButton button,
    ShortcutAction action,
  ) {
    switch (action) {
      case ShortcutAction.controllerLookupCursorLeft:
      case ShortcutAction.controllerLookupCursorRight:
      case ShortcutAction.controllerLookupLineUp:
      case ShortcutAction.controllerLookupLineDown:
        // Look up when the cursor stops: a single step looks up at once, a
        // held direction only steps and looks up once on release.
        _startRepeat(
          button,
          repeats: true,
          first: () {
            _move(t, action);
            unawaited(_lookup(t));
          },
          repeat: () => _move(t, action),
          onRepeatEnd: () => unawaited(_lookup(t)),
        );
      case ShortcutAction.controllerLookupShrinkEnd:
      case ShortcutAction.controllerLookupExtendEnd:
        final bool extend = action == ShortcutAction.controllerLookupExtendEnd;
        _startRepeat(
          button,
          repeats: true,
          first: () {
            if (_adjustEnd(t, extend: extend)) unawaited(_lookup(t));
          },
          repeat: () => _adjustEnd(t, extend: extend),
          onRepeatEnd: () => unawaited(_lookup(t)),
        );
      case ShortcutAction.controllerLookupToggleGranularity:
        _wordGranularity = !_wordGranularity;
        notifyListeners();
      case ShortcutAction.controllerLookupMine:
        _lookupAction(CompanionLookupActions.mine);
      case ShortcutAction.controllerLookupPlayAudio:
        _lookupAction(CompanionLookupActions.playAudio);
      case ShortcutAction.controllerLookupNextEntry:
        _lookupAction(CompanionLookupActions.nextEntry);
      case ShortcutAction.controllerLookupPrevEntry:
        _lookupAction(CompanionLookupActions.prevEntry);
      case ShortcutAction.controllerLookupEnterResult:
        // Only the in-page popup has a cursor to enter; a lookup on the
        // companion is driven from the panel (R1), nothing to do here.
        if (_companionLookup == null && _lookupOpen) {
          unawaited(t.enterResult());
        }
      case ShortcutAction.controllerLookupCloseOrExit:
        if (_lookupOpen) {
          _closeLookup();
        } else {
          if (_lbHeld) _lbUsed = true;
          _setActive(false);
        }
      default:
        // Only controllerLookup actions resolve here ([actionFor]).
        break;
    }
  }

  /// A cursor / line step: clears the right-end cap (the selection starts
  /// over at the new position) and the last match length.
  void _move(ControllerLookupTarget t, ShortcutAction move) {
    _maxGraphemes = null;
    _lastMatched = null;
    final bool word = _wordGranularity && t.hasWordSteps;
    _pendingStep = switch (move) {
      ShortcutAction.controllerLookupCursorLeft => t.stepCursor(-1, word: word),
      ShortcutAction.controllerLookupCursorRight => t.stepCursor(1, word: word),
      ShortcutAction.controllerLookupLineUp => t.stepLine(-1),
      ShortcutAction.controllerLookupLineDown => t.stepLine(1),
      _ => _pendingStep,
    };
  }

  /// Moves the selection's right end by one grapheme ([extend] = +1, else −1).
  /// Returns whether the cap changed (a lookup is worth running).
  ///
  /// −1: `(last match length ?? queried cap) − 1`, at least 1 (the smaller of
  /// the two when both are known: a held shrink runs ahead of its lookups).
  /// +1: the larger of the two, plus one (so a cap the dictionary could not
  /// fill keeps growing); past the graphemes left on the line
  /// ([ControllerLookupTarget.graphemesFromCursor]) the cap returns to null
  /// (unlimited). With nothing known yet (no match, no cap) −1 does nothing.
  bool _adjustEnd(ControllerLookupTarget t, {required bool extend}) {
    final int? before = _maxGraphemes;
    final int? matched = _lastMatched;
    if (extend) {
      final int next = math.max(before ?? 0, matched ?? 0) + 1;
      _maxGraphemes = next > t.graphemesFromCursor ? null : next;
    } else {
      final int? base = before == null
          ? matched
          : (matched == null ? before : math.min(before, matched));
      if (base == null) return false;
      _maxGraphemes = math.max(1, base - 1);
    }
    return _maxGraphemes != before;
  }

  /// Looks up at the cursor (after the step in flight) with the current cap
  /// and records the match length unless a later lookup started meanwhile.
  Future<void> _lookup(ControllerLookupTarget t) async {
    final int seq = ++_lookupSeq;
    final Future<void>? step = _pendingStep;
    if (step != null) await step;
    if (seq != _lookupSeq || !_active) return;
    final int matched = await t.lookupAtCursor(maxGraphemes: _maxGraphemes);
    if (seq != _lookupSeq) return;
    _lastMatched = matched > 0 ? matched : null;
  }

  /// Mine / audio / entry moves go to the companion's lookup when lookups
  /// open there, else to the visible in-page popup.
  void _lookupAction(String action) {
    final CompanionControllerSink? c = _companionLookup;
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
    final CompanionControllerSink? c = _companionLookup;
    if (c != null) {
      c.sendLookupAction(CompanionLookupActions.close);
    } else {
      // The page's own popup close path (universal Back closes the popup
      // before anything else), so hand B to the page.
      redispatch?.call(GamepadButton.b);
    }
  }

  // ---- repeat (400 ms, then every 150 ms) ----

  /// Runs [first] now; with [repeats], runs [repeat] (default [first]) every
  /// [repeatInterval] once [repeatDelay] has passed, until the button is
  /// released. [onRepeatEnd] runs on that release when at least one repeat
  /// fired.
  void _startRepeat(
    GamepadButton button, {
    required bool repeats,
    required VoidCallback first,
    VoidCallback? repeat,
    VoidCallback? onRepeatEnd,
  }) {
    if (_repeating == button) return; // processor / OS repeat of a held key
    _stopRepeat();
    first();
    if (!repeats) return;
    final VoidCallback tick = repeat ?? first;
    _repeating = button;
    _onRepeatEnd = onRepeatEnd;
    _repeated = false;
    _repeatTimer = Timer(repeatDelay, () {
      _repeatTimer = Timer.periodic(repeatInterval, (_) {
        _repeated = true;
        tick();
      });
    });
  }

  /// The held [_repeating] button was released: stop, and finish a repeated
  /// move with its [_onRepeatEnd] (the one lookup of a held direction).
  void _endRepeat() {
    final VoidCallback? end = _repeated ? _onRepeatEnd : null;
    _stopRepeat();
    end?.call();
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _repeating = null;
    _onRepeatEnd = null;
    _repeated = false;
  }

  // ---- state ----

  /// Forgets the selection cap, the last match and any lookup in flight.
  void _clearLookupState() {
    _maxGraphemes = null;
    _lastMatched = null;
    _pendingStep = null;
    _lookupSeq++;
    _stickBurst = false;
    _stickMoved = false;
  }

  void _setActive(bool value) {
    if (_active == value) return;
    _active = value;
    _lbTimer?.cancel();
    _stopRepeat();
    _clearLookupState();
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
    _clearLookupState();
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
    _rawInputOwner = null;
    redispatch = null;
    shortcutRegistry = null;
    _wordGranularity = true;
    popupHooks = () => DictionaryPopupGamepadRegistry.current;
  }
}
