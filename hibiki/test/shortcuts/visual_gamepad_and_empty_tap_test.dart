import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_button_widget.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:hibiki/src/shortcuts/visual/keyboard_layout_view.dart';

/// TODO-1050a (gamepad brand glyph rendering) + TODO-1060② (empty-key tap opens
/// assignment) behavioural coverage on the standalone visual sub-widget.
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  HibikiShortcutRegistry buildRegistry() =>
      HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  Future<void> pumpView(
    WidgetTester tester,
    HibikiShortcutRegistry registry,
    ShortcutScope scope, {
    void Function(LogicalKeyboardKey)? onEmptyKeyTap,
    void Function(GamepadButton)? onEmptyGamepadTap,
    void Function(GamepadButton, List<ShortcutAction>)? onGamepadTap,
    GamepadBrand brand = GamepadBrand.xbox,
    Size surfaceSize = const Size(1200, 2400),
  }) async {
    tester.view.physicalSize = surfaceSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: KeyboardLayoutView(
                registry: registry,
                scope: scope,
                gamepadBrand: brand,
                onEmptyKeyTap: onEmptyKeyTap,
                onGamepadTap: onGamepadTap,
                onEmptyGamepadTap: onEmptyGamepadTap,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'gamepad face buttons render with Xbox glyphs (A/B/X/Y) by default',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpView(tester, registry, ShortcutScope.reader);

    // The gamepad panel renders one keyed knob per known button.
    expect(find.byKey(const Key('gamepad_btn_A')), findsOneWidget);
    expect(find.byKey(const Key('gamepad_btn_B')), findsOneWidget);
    // Xbox face-button symbols are letters.
    final GamepadButtonWidget aWidget = tester.widget<GamepadButtonWidget>(
      find.byKey(const Key('gamepad_btn_A')),
    );
    expect(aWidget.brand, GamepadBrand.xbox);
    expect(
        GamepadGlyphs.glyphFor(GamepadButton.a, GamepadBrand.xbox).symbol, 'A');
    // The rendered text for A is the Xbox 'A' glyph.
    expect(
      find.descendant(
        of: find.byKey(const Key('gamepad_btn_A')),
        matching: find.text('A'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('PlayStation brand renders ✕○□△ face-button symbols',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpView(tester, registry, ShortcutScope.reader,
        brand: GamepadBrand.playstation);

    // A -> ✕ under PlayStation.
    expect(
      find.descendant(
        of: find.byKey(const Key('gamepad_btn_A')),
        matching: find.text('✕'),
      ),
      findsOneWidget,
    );
    // B -> ○.
    expect(
      find.descendant(
        of: find.byKey(const Key('gamepad_btn_B')),
        matching: find.text('○'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a bound gamepad button is tappable and routes onGamepadTap',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    // Seed a gamepad binding so its knob is bound + tappable.
    registry.updateBinding(
      ShortcutAction.readerToggleBookmark,
      const ShortcutBindingSet(
        gamepadBindings: <GamepadBinding>[GamepadBinding(GamepadButton.a)],
      ),
    );
    GamepadButton? tappedButton;
    await pumpView(
      tester,
      registry,
      ShortcutScope.reader,
      onGamepadTap: (GamepadButton b, List<ShortcutAction> actions) {
        tappedButton = b;
      },
    );

    await tester.tap(find.byKey(const Key('gamepad_btn_A')));
    await tester.pumpAndSettle();
    expect(tappedButton, GamepadButton.a);
  });

  testWidgets('an unbound gamepad button routes onEmptyGamepadTap',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    GamepadButton? emptyTapped;
    await pumpView(
      tester,
      registry,
      ShortcutScope.reader,
      onEmptyGamepadTap: (GamepadButton b) => emptyTapped = b,
    );
    // 'mode' has no reader default -> unbound -> empty tap path.
    await tester.tap(find.byKey(const Key('gamepad_btn_Mode')));
    await tester.pumpAndSettle();
    expect(emptyTapped, GamepadButton.mode);
  });

  testWidgets(
      'TODO-1060②: tapping an UNBOUND keycap fires onEmptyKeyTap (un-deferred)',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    LogicalKeyboardKey? tappedEmpty;
    await pumpView(
      tester,
      registry,
      ShortcutScope.reader,
      onEmptyKeyTap: (LogicalKeyboardKey k) => tappedEmpty = k,
    );

    // F9 has no reader default -> it is the empty/unbound slot. It must now be
    // tappable and route the key-first empty handler (previously a no-op).
    await tester.tap(
      find.byKey(Key('keycap_${LogicalKeyboardKey.f9.keyId}')),
    );
    await tester.pumpAndSettle();
    expect(tappedEmpty, LogicalKeyboardKey.f9);
  });

  testWidgets(
      'empty keycap stays non-tappable when no onEmptyKeyTap is provided '
      '(back-compat)', (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    // No onEmptyKeyTap passed -> unbound keys must have no InkWell (old default).
    await pumpView(tester, registry, ShortcutScope.reader);
    final Finder f9InkWell = find.descendant(
      of: find.byKey(Key('keycap_${LogicalKeyboardKey.f9.keyId}')),
      matching: find.byType(InkWell),
    );
    expect(f9InkWell, findsNothing);
  });
}
