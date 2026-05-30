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
  lookup,
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
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      return CaretAction.lookup;
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
      case GamepadButton.a:
        return CaretAction.lookup;
      case GamepadButton.b:
        return CaretAction.dismissOrExit;
      // ignore: no_default_cases
      default:
        return null;
    }
  }

  /// Whether a keyboard key should ENTER the cursor when it is inactive and the
  /// book (not the bottom chrome) holds focus. A / Enter = "activate / enter".
  static bool isEnterTriggerKeyboard(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.gameButtonA;

  /// Whether a gamepad button should ENTER the cursor when it is inactive. Only
  /// A (the "activate" button) enters; B is reserved for back/dismiss.
  static bool isEnterTriggerGamepad(GamepadButton button) =>
      button == GamepadButton.a;
}
