import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/reader_caret_router.dart';

void main() {
  group('ReaderCaretRouter.decideKeyboard (cursor active)', () {
    test('Tab steps forward, Shift+Tab steps backward', () {
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.tab, shift: false),
        CaretAction.stepForward,
      );
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.tab, shift: true),
        CaretAction.stepBackward,
      );
    });

    test('arrows map to physical move directions', () {
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.arrowUp,
            shift: false),
        CaretAction.moveUp,
      );
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.arrowDown,
            shift: false),
        CaretAction.moveDown,
      );
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.arrowLeft,
            shift: false),
        CaretAction.moveLeft,
      );
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.arrowRight,
            shift: false),
        CaretAction.moveRight,
      );
    });

    test('Enter / game A activate; Escape / game B dismiss-or-exit', () {
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.enter,
            shift: false),
        CaretAction.activate,
      );
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.gameButtonA,
            shift: false),
        CaretAction.activate,
      );
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.escape,
            shift: false),
        CaretAction.dismissOrExit,
      );
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.gameButtonB,
            shift: false),
        CaretAction.dismissOrExit,
      );
    });

    test('unrelated keys return null (fall through to existing handling)', () {
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.keyD, shift: false),
        isNull,
      );
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.space,
            shift: false),
        isNull,
      );
    });
  });

  group('ReaderCaretRouter.decideGamepad (cursor active)', () {
    test('D-pad maps to physical move directions', () {
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.dpadUp),
          CaretAction.moveUp);
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.dpadDown),
          CaretAction.moveDown);
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.dpadLeft),
          CaretAction.moveLeft);
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.dpadRight),
          CaretAction.moveRight);
    });

    test('A activates, B dismiss-or-exit', () {
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.a),
          CaretAction.activate);
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.b),
          CaretAction.dismissOrExit);
    });

    test('X / Y / shoulders return null (kept for bookmark/chrome/page-turn)',
        () {
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.x), isNull);
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.y), isNull);
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.lb), isNull);
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.rb), isNull);
    });
  });

  group('ReaderCaretRouter enter triggers (cursor inactive)', () {
    test('Enter and game A enter the cursor from the keyboard path', () {
      expect(ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.enter),
          isTrue);
      expect(
          ReaderCaretRouter.isEnterTriggerKeyboard(
              LogicalKeyboardKey.gameButtonA),
          isTrue);
    });

    test('other keys are not enter triggers', () {
      expect(ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.tab),
          isFalse);
      expect(
          ReaderCaretRouter.isEnterTriggerKeyboard(
              LogicalKeyboardKey.arrowRight),
          isFalse);
      expect(ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.space),
          isFalse);
    });

    test('only A enters the cursor from the gamepad path', () {
      expect(ReaderCaretRouter.isEnterTriggerGamepad(GamepadButton.a), isTrue);
      expect(ReaderCaretRouter.isEnterTriggerGamepad(GamepadButton.b), isFalse);
      expect(ReaderCaretRouter.isEnterTriggerGamepad(GamepadButton.x), isFalse);
      expect(ReaderCaretRouter.isEnterTriggerGamepad(GamepadButton.dpadRight),
          isFalse);
    });
  });
}
