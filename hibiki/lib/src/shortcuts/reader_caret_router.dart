import 'package:flutter/services.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

/// One discrete action against the char-level reading cursor while it is active.
///
/// The physical [moveUp]/[moveDown]/[moveLeft]/[moveRight] directions are kept
/// *physical* on purpose: their "logical" meaning (advance one char vs. move one
/// line, forwards vs. backwards) depends on the book's writing-mode and is
/// resolved by the JS caret module, which is the single source of truth for the
/// DOM's computed `writing-mode`. This Dart side only does the pure
/// input → action mapping so it can be unit-tested without a WebView.
enum CaretAction {
  stepForward,
  stepBackward,
  moveUp,
  moveDown,
  moveLeft,
  moveRight,

  /// Context "click" at the cursor (A / Enter): follow a hyperlink, click an
  /// interactive control (popup audio/expand buttons), or — on plain text —
  /// look up the word. The JS [hoshiCaret.activate] decides which, mirroring a
  /// mouse click / Enter on whatever the cursor sits on.
  activate,

  /// Plain word lookup. Kept as the fallback that [activate] performs on plain
  /// text; no input maps directly to it any more.
  lookup,

  /// Gamepad hold-A / long-press at the cursor. This is separate from
  /// [activate] so a dictionary popup summary can mark/unmark a dictionary
  /// without also toggling the disclosure row.
  longPress,

  /// Jump the caret to the NEXT dictionary section header in a multi-dictionary
  /// popup (Yomitan-style "go to dictionary"). Popup-only; no-op on the reader,
  /// which has no dictionary sections. Keyboard `]`, gamepad RT.
  jumpDictNext,

  /// Jump the caret to the PREVIOUS dictionary section header. Keyboard `[`,
  /// gamepad LT. See [jumpDictNext].
  jumpDictPrev,
  dismissOrExit,
}

/// Pure router for reader cursor input. No widget/WebView state — both the
/// Android key-event path and the desktop polled-gamepad path funnel through
/// these maps so a controller and a keyboard reach the exact same cursor
/// actions (mirrors how [GamepadFrameProcessor] is a platform-free normalizer).
class ReaderCaretRouter {
  ReaderCaretRouter._();

  /// Meaning of a keyboard key *while the cursor is active*; null = not a cursor
  /// key, leave it to the existing reader handling.
  static CaretAction? decideKeyboard(LogicalKeyboardKey key,
      {required bool shift}) {
    if (key == LogicalKeyboardKey.tab) {
      return shift ? CaretAction.stepBackward : CaretAction.stepForward;
    }
    if (key == LogicalKeyboardKey.arrowUp) return CaretAction.moveUp;
    if (key == LogicalKeyboardKey.arrowDown) return CaretAction.moveDown;
    if (key == LogicalKeyboardKey.arrowLeft) return CaretAction.moveLeft;
    if (key == LogicalKeyboardKey.arrowRight) return CaretAction.moveRight;
    // Jump to the next/previous dictionary section in a multi-dict popup
    // (Yomitan "go to dictionary"). `]` next, `[` previous — keys a keyboard
    // user can reach without a chord; the reader ignores them (no dict sections,
    // so jumpDict no-ops → blocked).
    if (key == LogicalKeyboardKey.bracketRight) return CaretAction.jumpDictNext;
    if (key == LogicalKeyboardKey.bracketLeft) return CaretAction.jumpDictPrev;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      return CaretAction.activate;
    }
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.gameButtonB) {
      return CaretAction.dismissOrExit;
    }
    return null;
  }

  /// Meaning of a gamepad button *while the cursor is active*; null = not a
  /// cursor button (X = bookmark, Y = chrome, LB/RB = page-turn keep working).
  static CaretAction? decideGamepad(GamepadButton button) {
    switch (button) {
      case GamepadButton.dpadUp:
        return CaretAction.moveUp;
      case GamepadButton.dpadDown:
        return CaretAction.moveDown;
      case GamepadButton.dpadLeft:
        return CaretAction.moveLeft;
      case GamepadButton.dpadRight:
        return CaretAction.moveRight;
      // RT/LT jump to the next/previous dictionary section in a multi-dict
      // popup (Yomitan "go to dictionary"). The triggers are free while the
      // caret is active (the popup never paginates, so LB/RB own page-scroll and
      // the triggers were unused). Reader caret ignores them (no dict sections).
      case GamepadButton.rt:
        return CaretAction.jumpDictNext;
      case GamepadButton.lt:
        return CaretAction.jumpDictPrev;
      case GamepadButton.a:
        return CaretAction.activate;
      case GamepadButton.b:
        return CaretAction.dismissOrExit;
      // ignore: no_default_cases
      default:
        return null;
    }
  }

  /// Whether a keyboard key should ENTER the cursor when it is inactive and the
  /// book (not the bottom chrome) holds focus.
  ///
  /// TODO-700 T7: the enter trigger is REMAPPABLE. [enterKeys] is the set of
  /// keyboard keys bound to [ShortcutAction.readerEnterCaret]; the reader passes
  /// it from the registry. When omitted (pure unit tests, or any call site
  /// without a registry) it defaults to the original hard-coded `Enter` +
  /// `gameButtonA`, so existing behaviour and tests are unchanged.
  ///
  /// [focusNavEnabled] mirrors the global keyboard/gamepad focus navigation
  /// switch: when the switch is off, reader caret navigation stays inactive.
  static bool isEnterTriggerKeyboard(
    LogicalKeyboardKey key, {
    bool focusNavEnabled = true,
    Set<LogicalKeyboardKey>? enterKeys,
  }) =>
      focusNavEnabled && (enterKeys ?? _defaultEnterKeys).contains(key);

  /// Whether a gamepad button should ENTER the cursor when it is inactive.
  ///
  /// TODO-700 T7: REMAPPABLE — [enterButtons] is the set of gamepad buttons bound
  /// to [ShortcutAction.readerEnterCaret] (passed from the registry by the
  /// reader). When omitted it defaults to the original hard-coded `A`, so the
  /// pure unit tests and any registry-less call site behave exactly as before.
  /// Gated on [focusNavEnabled] the same way as [isEnterTriggerKeyboard].
  static bool isEnterTriggerGamepad(
    GamepadButton button, {
    bool focusNavEnabled = true,
    Set<GamepadButton>? enterButtons,
  }) =>
      focusNavEnabled &&
      (enterButtons ?? _defaultEnterButtons).contains(button);

  /// Default enter-caret triggers — the historical hard-coded set, used when a
  /// caller does not supply the live [ShortcutAction.readerEnterCaret] bindings.
  // Non-const: LogicalKeyboardKey overrides ==, so it cannot live in a const Set.
  static final Set<LogicalKeyboardKey> _defaultEnterKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.gameButtonA,
  };
  static const Set<GamepadButton> _defaultEnterButtons = <GamepadButton>{
    GamepadButton.a,
  };
}
