import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/shortcut_settings_page.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/misc/show_app_dialog.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  HibikiShortcutRegistry buildRegistry() =>
      HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

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

  // Reproduces the real-device layering: the dialog lives under
  // wrapWithGlobalNavigation, whose Shortcuts maps bare Space to DoNothingIntent
  // and (focus navigation off) Tab too. If the capture Focus loses primary focus,
  // bare letter/digit keys bubble up here and get silently swallowed — TODO-838.
  Future<void> pumpDialogWithGlobalNav(
    WidgetTester tester,
    HibikiShortcutRegistry registry, {
    ShortcutAction action = ShortcutAction.readerToggleBookmark,
  }) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder: (BuildContext context, Widget? child) =>
              wrapWithGlobalNavigation(
            navigatorKey: navigatorKey,
            focusNavigationEnabled: false,
            registry: registry,
            child: child ?? const SizedBox.shrink(),
          ),
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

  Future<void> pumpDialogHost(
    WidgetTester tester,
    HibikiShortcutRegistry registry, {
    ShortcutAction action = ShortcutAction.readerToggleBookmark,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () async {
                  final ShortcutBindingEditResult? result =
                      await showAppDialog<ShortcutBindingEditResult>(
                    context: context,
                    builder: (BuildContext ctx) => ShortcutBindingEditDialog(
                      action: action,
                      registry: registry,
                      initial: const ShortcutBindingSet(),
                    ),
                  );
                  if (result == null) return;
                  registry.updateBindingWithReassignments(
                    action,
                    result.bindings,
                    removeKeyboardConflicts: result.keyboardReassignments,
                    removeGamepadConflicts: result.gamepadReassignments,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
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
    expect(find.widgetWithText(HibikiTagChip, 'Tab'), findsOneWidget);
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

    expect(find.widgetWithText(HibikiTagChip, 'Escape'), findsOneWidget);
    expect(find.byType(ShortcutBindingEditDialog), findsOneWidget);
  });

  testWidgets(
      'capturing a key already bound in scope warns and cancel keeps draft unchanged',
      (WidgetTester tester) async {
    // Escape is a reader-scope default (the reader "back" key = dismiss dict /
    // exit book), so trying to bind it to another reader action must ask before
    // moving ownership.
    await pumpDialog(tester, buildRegistry(),
        action: ShortcutAction.readerToggleBookmark);
    await startCapture(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      find.text(t.shortcut_conflict_replace_confirm(
        s: t.shortcut_action_reader_dismiss_dict,
      )),
      findsOneWidget,
    );
    await tester.tap(find.text(t.dialog_cancel).last);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(HibikiTagChip, 'Escape'), findsNothing);
    expect(
      find.text(t.shortcut_conflict(s: t.shortcut_action_reader_dismiss_dict)),
      findsOneWidget,
    );
  });

  testWidgets(
      'conflict confirmation reassigns from old action to new action on OK',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.readerToggleBookmark,
    );
    await startCapture(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(HibikiTagChip, 'Escape'), findsOneWidget);
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    const InputBinding escape = InputBinding(key: LogicalKeyboardKey.escape);
    expect(
      registry.bindingsFor(ShortcutAction.readerDismissDict).keyboardBindings,
      isNot(contains(escape)),
    );
    expect(
      registry
          .bindingsFor(ShortcutAction.readerToggleBookmark)
          .keyboardBindings,
      contains(escape),
    );
  });

  testWidgets(
      'deleting a confirmed keyboard conflict chip keeps the old action binding',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.readerToggleBookmark,
    );
    await startCapture(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    final Finder escapeChip = find.widgetWithText(HibikiTagChip, 'Escape');
    expect(escapeChip, findsOneWidget);
    await tester.tap(find.descendant(
      of: escapeChip,
      matching: find.byIcon(Icons.close),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    const InputBinding escape = InputBinding(key: LogicalKeyboardKey.escape);
    expect(
      registry.bindingsFor(ShortcutAction.readerDismissDict).keyboardBindings,
      contains(escape),
    );
    expect(
      registry
          .bindingsFor(ShortcutAction.readerToggleBookmark)
          .keyboardBindings,
      isNot(contains(escape)),
    );
  });

  testWidgets(
      'deleting a confirmed gamepad conflict chip keeps the old action binding',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.readerToggleBookmark,
    );

    await tester.tap(find.text(t.shortcut_gamepad).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(GamepadButton.dpadRight.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    final Finder dpadChip =
        find.widgetWithText(HibikiTagChip, GamepadButton.dpadRight.label);
    expect(dpadChip, findsOneWidget);
    await tester.tap(find.descendant(
      of: dpadChip,
      matching: find.byIcon(Icons.close),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    const GamepadBinding dpadRight = GamepadBinding(GamepadButton.dpadRight);
    expect(
      registry.bindingsFor(ShortcutAction.readerPageForward).gamepadBindings,
      contains(dpadRight),
    );
    expect(
      registry.bindingsFor(ShortcutAction.readerToggleBookmark).gamepadBindings,
      isNot(contains(dpadRight)),
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

    expect(find.widgetWithText(HibikiTagChip, 'Ctrl+KeyB'), findsOneWidget);
  });

  testWidgets(
      'bare single key is captured even under global navigation Shortcuts',
      (WidgetTester tester) async {
    // TODO-838: with the dialog nested under wrapWithGlobalNavigation, the
    // capture Focus must deterministically hold primary focus so a bare letter
    // key reaches _onKeyEvent instead of bubbling to the global Shortcuts and
    // getting dropped. Covers both "bare single key recorded" and "global layer
    // does not steal it".
    await pumpDialogWithGlobalNav(tester, buildRegistry());
    await startCapture(tester);
    expect(find.text(t.shortcut_press_key), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(HibikiTagChip, 'KeyB'), findsOneWidget);
    expect(find.text(t.shortcut_press_key), findsNothing);
    expect(find.byType(ShortcutBindingEditDialog), findsOneWidget);
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
    expect(find.byType(HibikiTagChip), findsNothing);
    expect(find.byType(ShortcutBindingEditDialog), findsOneWidget);
  });
}
