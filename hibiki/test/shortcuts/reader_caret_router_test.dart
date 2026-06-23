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

    test(
        '] / [ jump to next / previous dictionary section (TODO-070 go-to-dict)',
        () {
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.bracketRight,
            shift: false),
        CaretAction.jumpDictNext,
      );
      expect(
        ReaderCaretRouter.decideKeyboard(LogicalKeyboardKey.bracketLeft,
            shift: false),
        CaretAction.jumpDictPrev,
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

    test('RT / LT jump to next / previous dictionary section (TODO-070)', () {
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.rt),
          CaretAction.jumpDictNext);
      expect(ReaderCaretRouter.decideGamepad(GamepadButton.lt),
          CaretAction.jumpDictPrev);
    });

    test('long-press is a distinct caret action for hold-A routing', () {
      expect(CaretAction.values, contains(CaretAction.longPress));
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

    test('global focus navigation switch gates cursor entry', () {
      expect(
        ReaderCaretRouter.isEnterTriggerKeyboard(
          LogicalKeyboardKey.enter,
          focusNavEnabled: false,
        ),
        isFalse,
      );
      expect(
        ReaderCaretRouter.isEnterTriggerKeyboard(
          LogicalKeyboardKey.gameButtonA,
          focusNavEnabled: false,
        ),
        isFalse,
      );
      expect(
        ReaderCaretRouter.isEnterTriggerGamepad(
          GamepadButton.a,
          focusNavEnabled: false,
        ),
        isFalse,
      );
    });
  });

  // TODO-700 T7: the enter-caret trigger is REMAPPABLE — isEnterTrigger* accept
  // the live readerEnterCaret bindings. With no override they keep the historical
  // Enter/A defaults (above); with an override only the supplied keys/buttons
  // enter the cursor.
  group('ReaderCaretRouter enter triggers are remappable (TODO-700 T7)', () {
    test('custom enterKeys: only the bound key enters, default A/Enter do not',
        () {
      final Set<LogicalKeyboardKey> bound = <LogicalKeyboardKey>{
        LogicalKeyboardKey.keyG,
      };
      expect(
        ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.keyG,
            enterKeys: bound),
        isTrue,
      );
      expect(
        ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.enter,
            enterKeys: bound),
        isFalse,
      );
    });

    test(
        'custom enterButtons: only the bound button enters, default A does not',
        () {
      const Set<GamepadButton> bound = <GamepadButton>{GamepadButton.y};
      expect(
        ReaderCaretRouter.isEnterTriggerGamepad(GamepadButton.y,
            enterButtons: bound),
        isTrue,
      );
      expect(
        ReaderCaretRouter.isEnterTriggerGamepad(GamepadButton.a,
            enterButtons: bound),
        isFalse,
      );
    });

    test('an empty override disables enter entirely (no key/button enters)',
        () {
      expect(
        ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.enter,
            enterKeys: <LogicalKeyboardKey>{}),
        isFalse,
      );
      expect(
        ReaderCaretRouter.isEnterTriggerGamepad(GamepadButton.a,
            enterButtons: const <GamepadButton>{}),
        isFalse,
      );
    });

    test('focusNavEnabled:false overrides any custom binding', () {
      expect(
        ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.keyG,
            focusNavEnabled: false,
            enterKeys: <LogicalKeyboardKey>{LogicalKeyboardKey.keyG}),
        isFalse,
      );
    });
  });

  // BUG-161: the reader's char-cursor focus navigation must follow the global
  // "键盘/手柄焦点导航" switch (experimentalFocusNavigationEnabled, default off).
  // When focus navigation is disabled, Enter / game A must NOT enter the cursor —
  // the reader falls back to plain page-turn / shortcut handling.
  group('ReaderCaretRouter enter triggers gated on focusNavEnabled', () {
    test('focusNavEnabled:false → Enter / game A do not enter the cursor', () {
      expect(
        ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.enter,
            focusNavEnabled: false),
        isFalse,
      );
      expect(
        ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.gameButtonA,
            focusNavEnabled: false),
        isFalse,
      );
      expect(
        ReaderCaretRouter.isEnterTriggerGamepad(GamepadButton.a,
            focusNavEnabled: false),
        isFalse,
      );
    });

    test('focusNavEnabled defaults true (existing call sites unchanged)', () {
      expect(ReaderCaretRouter.isEnterTriggerKeyboard(LogicalKeyboardKey.enter),
          isTrue);
      expect(ReaderCaretRouter.isEnterTriggerGamepad(GamepadButton.a), isTrue);
    });
  });
}
