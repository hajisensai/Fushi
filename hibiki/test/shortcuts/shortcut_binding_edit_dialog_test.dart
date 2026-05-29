import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/shortcut_settings_page.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  HibikiShortcutRegistry buildRegistry(
          [TargetPlatform platform = TargetPlatform.windows]) =>
      HibikiShortcutRegistry()..loadDefaults(platform);

  Future<void> pumpDialog(
    WidgetTester tester,
    HibikiShortcutRegistry registry, {
    ShortcutAction action = ShortcutAction.readerToggleBookmark,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ShortcutBindingEditDialog(
                action: action,
                registry: registry,
                initial: const ShortcutBindingSet(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> startCapture(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, t.shortcut_keyboard));
    await tester.pumpAndSettle();
  }

  testWidgets('Tab is captured as a binding instead of moving focus',
      (WidgetTester tester) async {
    await pumpDialog(tester, buildRegistry());
    await startCapture(tester);
    expect(find.text(t.shortcut_press_key), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    // Tab recorded as a chip, capture prompt gone, dialog still open.
    expect(find.widgetWithText(Chip, 'Tab'), findsOneWidget);
    expect(find.text(t.shortcut_press_key), findsNothing);
    expect(find.byType(ShortcutBindingEditDialog), findsOneWidget);
  });

  testWidgets('Escape is captured, not treated as a dialog dismiss',
      (WidgetTester tester) async {
    // homeFocusSearch lives in a scope where Escape is unbound by default, so
    // it is recorded rather than rejected as a conflict — this isolates the
    // "Escape must not leak to the dismiss intent" behaviour.
    await pumpDialog(tester, buildRegistry(),
        action: ShortcutAction.homeFocusSearch);
    await startCapture(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(Chip, 'Escape'), findsOneWidget);
    expect(find.byType(ShortcutBindingEditDialog), findsOneWidget);
  });

  testWidgets('capturing a key already bound in scope shows a conflict warning',
      (WidgetTester tester) async {
    // Escape is a reader-scope default (toggle chrome / dismiss dict), so
    // trying to bind it to another reader action must be rejected.
    await pumpDialog(tester, buildRegistry(),
        action: ShortcutAction.readerToggleBookmark);
    await startCapture(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(Chip, 'Escape'), findsNothing);
    expect(
      find.text(t.shortcut_conflict(s: t.shortcut_action_reader_toggle_chrome)),
      findsOneWidget,
    );
  });

  testWidgets('Ctrl modifier is captured with the key',
      (WidgetTester tester) async {
    await pumpDialog(tester, buildRegistry());
    await startCapture(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(Chip, 'Ctrl+KeyB'), findsOneWidget);
  });

  testWidgets('stop-capture control exits capture without binding a key',
      (WidgetTester tester) async {
    await pumpDialog(tester, buildRegistry());
    await startCapture(tester);
    expect(find.text(t.shortcut_press_key), findsOneWidget);

    await tester.tap(find.byKey(const Key('shortcut_stop_capture')));
    await tester.pumpAndSettle();

    // Capture aborted: prompt gone, no chips added, dialog still open.
    expect(find.text(t.shortcut_press_key), findsNothing);
    expect(find.byType(Chip), findsNothing);
    expect(find.byType(ShortcutBindingEditDialog), findsOneWidget);
  });

  testWidgets('gamepad section is hidden on a desktop registry',
      (WidgetTester tester) async {
    await pumpDialog(tester, buildRegistry(TargetPlatform.windows));
    // Keyboard section stays; gamepad section (label + add button) is gone.
    expect(find.text(t.shortcut_keyboard), findsWidgets);
    expect(find.text(t.shortcut_gamepad), findsNothing);
  });

  testWidgets('gamepad section is shown on a mobile registry',
      (WidgetTester tester) async {
    await pumpDialog(tester, buildRegistry(TargetPlatform.android));
    expect(find.text(t.shortcut_gamepad), findsWidgets);
  });
}
