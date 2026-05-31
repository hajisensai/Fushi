import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/hibiki_gamepad_keyboard.dart';

import 'widget_test_helpers.dart';

void main() {
  group('HibikiGamepadKeyboard', () {
    testWidgets('A (ActivateIntent) on a focused key emits its character',
        (WidgetTester tester) async {
      final List<String> typed = <String>[];
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: HibikiGamepadKeyboard(
            onChar: typed.add,
            onBackspace: () => typed.add('<BS>'),
          ),
        ),
      ));
      await tester.pump();

      final HibikiFocusController controller =
          HibikiFocusRoot.controllerOf(tester.element(find.text('q')));
      controller.ensureFocus();
      await tester.pump();
      expect(controller.activeId, isNotNull,
          reason: 'keys register as gamepad focus targets');

      Actions.maybeInvoke<ActivateIntent>(
          controller.activeContext!, const ActivateIntent());
      await tester.pump();
      expect(typed, <String>['q'], reason: 'A presses the focused key');
    });

    testWidgets('D-pad moves focus to the next key, then A types it',
        (WidgetTester tester) async {
      final List<String> typed = <String>[];
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: HibikiGamepadKeyboard(
            onChar: typed.add,
            onBackspace: () {},
          ),
        ),
      ));
      await tester.pump();

      final HibikiFocusController controller =
          HibikiFocusRoot.controllerOf(tester.element(find.text('q')));
      controller.ensureFocus();
      await tester.pump();

      expect(controller.move(HibikiFocusDirection.right), isTrue,
          reason: 'D-pad right moves q → w');
      await tester.pump();
      Actions.maybeInvoke<ActivateIntent>(
          controller.activeContext!, const ActivateIntent());
      await tester.pump();
      expect(typed, <String>['w']);
    });

    testWidgets('the ⇧ / abc key cycles lower → upper → symbols',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: HibikiGamepadKeyboard(onChar: (_) {}, onBackspace: () {}),
        ),
      ));
      await tester.pump();
      expect(find.text('q'), findsOneWidget); // lower

      await tester.tap(find.text('⇧'));
      await tester.pump();
      expect(find.text('Q'), findsOneWidget); // upper

      await tester.tap(find.text('⇧'));
      await tester.pump();
      expect(find.text('1'), findsOneWidget); // symbols
      expect(find.text('abc'), findsOneWidget); // layer key flips to abc

      await tester.tap(find.text('abc'));
      await tester.pump();
      expect(find.text('q'), findsOneWidget); // back to lower
    });

    testWidgets('space / backspace / done keys fire their callbacks',
        (WidgetTester tester) async {
      final List<String> typed = <String>[];
      int backspaces = 0;
      int submits = 0;
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: HibikiGamepadKeyboard(
            onChar: typed.add,
            onBackspace: () => backspaces++,
            onSubmit: () => submits++,
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('␣'));
      await tester.pump();
      expect(typed, <String>[' '], reason: 'space emits a space character');

      await tester.tap(find.text('⌫'));
      await tester.pump();
      expect(backspaces, 1);

      await tester.tap(find.text('✓'));
      await tester.pump();
      expect(submits, 1);
    });
  });

  group('gamepad keyboard text wiring', () {
    test('insert adds a char at the cursor and advances it', () {
      final TextEditingController c = TextEditingController(text: 'ac');
      addTearDown(c.dispose);
      c.selection = const TextSelection.collapsed(offset: 1);
      gamepadKeyboardInsert(c, 'b');
      expect(c.text, 'abc');
      expect(c.selection.baseOffset, 2);
    });

    test('insert with no valid selection appends at the end', () {
      final TextEditingController c = TextEditingController(text: 'ab');
      addTearDown(c.dispose);
      gamepadKeyboardInsert(c, 'c');
      expect(c.text, 'abc');
    });

    test('insert replaces the current selection', () {
      final TextEditingController c = TextEditingController(text: 'axc');
      addTearDown(c.dispose);
      c.selection = const TextSelection(baseOffset: 1, extentOffset: 2);
      gamepadKeyboardInsert(c, 'b');
      expect(c.text, 'abc');
    });

    test('backspace deletes the char before the cursor', () {
      final TextEditingController c = TextEditingController(text: 'abc');
      addTearDown(c.dispose);
      c.selection = const TextSelection.collapsed(offset: 3);
      gamepadKeyboardBackspace(c);
      expect(c.text, 'ab');
      expect(c.selection.baseOffset, 2);
    });

    test('backspace at the start is a no-op', () {
      final TextEditingController c = TextEditingController(text: 'abc');
      addTearDown(c.dispose);
      c.selection = const TextSelection.collapsed(offset: 0);
      gamepadKeyboardBackspace(c);
      expect(c.text, 'abc');
    });

    test('backspace deletes the current selection', () {
      final TextEditingController c = TextEditingController(text: 'abXYc');
      addTearDown(c.dispose);
      c.selection = const TextSelection(baseOffset: 2, extentOffset: 4);
      gamepadKeyboardBackspace(c);
      expect(c.text, 'abc');
    });
  });
}
