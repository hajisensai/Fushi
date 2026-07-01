import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/shortcut_settings_page.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

/// TODO-1050b (mouse binding small-glyph rendering) + TODO-1060② (prefill from a
/// visual empty slot) behavioural coverage on the public ShortcutBindingEditDialog.
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  HibikiShortcutRegistry buildRegistry() =>
      HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  Future<void> pumpDialog(
    WidgetTester tester,
    HibikiShortcutRegistry registry, {
    required ShortcutAction action,
    ShortcutBindingSet initial = const ShortcutBindingSet(),
    LogicalKeyboardKey? prefillKey,
    GamepadButton? prefillButton,
  }) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ShortcutBindingEditDialog(
                action: action,
                registry: registry,
                initial: initial,
                prefillKey: prefillKey,
                prefillButton: prefillButton,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'TODO-1050b: existing mouse binding renders a small icon + localized label',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    // audiobookSeekToClickedSentence ships a MouseBinding(1) = middle click.
    await pumpDialog(
      tester,
      registry,
      action: ShortcutAction.audiobookSeekToClickedSentence,
      initial: const ShortcutBindingSet(
        mouseBindings: <MouseBinding>[MouseBinding(1)],
      ),
    );

    // The middle-click glyph (outlined mouse) and its localized label both show.
    expect(find.byIcon(Icons.mouse_outlined), findsOneWidget);
    expect(find.text(t.shortcut_mouse_middle), findsWidgets);
  });

  testWidgets('right-click mouse binding uses the filled mouse icon + label',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpDialog(
      tester,
      registry,
      action: ShortcutAction.audiobookSeekToClickedSentence,
      initial: const ShortcutBindingSet(
        mouseBindings: <MouseBinding>[MouseBinding(2)],
      ),
    );
    expect(find.byIcon(Icons.mouse), findsOneWidget);
    expect(find.text(t.shortcut_mouse_right), findsWidgets);
  });

  testWidgets(
      'TODO-1060②: prefillKey seeds the keyboard draft with the tapped key',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpDialog(
      tester,
      registry,
      action: ShortcutAction.homeFocusSearch,
      prefillKey: LogicalKeyboardKey.f9,
    );

    // Opening on an empty slot pre-adds an F9 chip (user can delete/confirm).
    expect(find.widgetWithText(HibikiTagChip, 'F9'), findsOneWidget);
  });

  testWidgets(
      'TODO-1060②: prefillButton seeds the gamepad draft with the tapped button',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpDialog(
      tester,
      registry,
      action: ShortcutAction.homeFocusSearch,
      prefillButton: GamepadButton.y,
    );
    expect(find.widgetWithText(HibikiTagChip, GamepadButton.y.label),
        findsOneWidget);
  });

  testWidgets('prefillKey does not duplicate an already-bound key',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    // Seed the action with F9 already, then prefill F9 again: must stay single.
    await pumpDialog(
      tester,
      registry,
      action: ShortcutAction.homeFocusSearch,
      initial: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.f9),
        ],
      ),
      prefillKey: LogicalKeyboardKey.f9,
    );
    expect(find.widgetWithText(HibikiTagChip, 'F9'), findsOneWidget);
  });
}
