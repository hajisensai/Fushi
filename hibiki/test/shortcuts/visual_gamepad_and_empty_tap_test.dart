import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_button_widget.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_button_assets.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_layout_view.dart';
import 'package:hibiki/src/shortcuts/visual/keyboard_layout_view.dart';

/// TODO-1050a (gamepad brand glyph rendering) + TODO-1060② (empty-key tap opens
/// assignment) behavioural coverage on the standalone visual sub-widgets.
/// TODO-942 P1: gamepad tests pump the new GamepadLayoutView full figure; the
/// keyboard empty-tap tests keep pumping KeyboardLayoutView (now keyboard-only).
/// Asserts the keyed gamepad button renders the expected Kenney asset image
/// (TODO-942: real controller icons replaced the hand-drawn text glyphs).
void expectButtonAsset(
  WidgetTester tester,
  String keyLabel,
  GamepadButton button,
  GamepadBrand brand,
) {
  final String? expected = GamepadButtonAssets.assetFor(button, brand);
  expect(expected, isNotNull, reason: '$button must map to a $brand asset');
  final Image image = tester.widget<Image>(
    find.descendant(
      of: find.byKey(Key('gamepad_btn_$keyLabel')),
      matching: find.byType(Image),
    ),
  );
  expect((image.image as AssetImage).assetName, expected);
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  HibikiShortcutRegistry buildRegistry() =>
      HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  Future<void> pumpGamepadView(
    WidgetTester tester,
    HibikiShortcutRegistry registry,
    ShortcutScope scope, {
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
              child: GamepadLayoutView(
                registry: registry,
                scope: scope,
                gamepadBrand: brand,
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

  Future<void> pumpKeyboardView(
    WidgetTester tester,
    HibikiShortcutRegistry registry,
    ShortcutScope scope, {
    void Function(LogicalKeyboardKey)? onEmptyKeyTap,
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
                onEmptyKeyTap: onEmptyKeyTap,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'gamepad face buttons render with Xbox Kenney icons (A/B/X/Y) by default',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpGamepadView(tester, registry, ShortcutScope.reader);

    // The gamepad figure renders one keyed knob per known button.
    expect(find.byKey(const Key('gamepad_btn_A')), findsOneWidget);
    expect(find.byKey(const Key('gamepad_btn_B')), findsOneWidget);
    final GamepadButtonWidget aWidget = tester.widget<GamepadButtonWidget>(
      find.byKey(const Key('gamepad_btn_A')),
    );
    expect(aWidget.brand, GamepadBrand.xbox);
    // TODO-942: face buttons now show the Xbox coloured-ABXY Kenney icons, not
    // hand-drawn text glyphs.
    expectButtonAsset(tester, 'A', GamepadButton.a, GamepadBrand.xbox);
    expectButtonAsset(tester, 'B', GamepadButton.b, GamepadBrand.xbox);
    expectButtonAsset(tester, 'X', GamepadButton.x, GamepadBrand.xbox);
    expectButtonAsset(tester, 'Y', GamepadButton.y, GamepadBrand.xbox);
  });

  testWidgets('PlayStation brand renders ✕○□△ Kenney face-button icons',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpGamepadView(tester, registry, ShortcutScope.reader,
        brand: GamepadBrand.playstation);

    // A -> ✕ (cross), B -> ○ (circle): the PlayStation coloured Kenney icons.
    expectButtonAsset(tester, 'A', GamepadButton.a, GamepadBrand.playstation);
    expectButtonAsset(tester, 'B', GamepadButton.b, GamepadBrand.playstation);
    expectButtonAsset(tester, 'X', GamepadButton.x, GamepadBrand.playstation);
    expectButtonAsset(tester, 'Y', GamepadButton.y, GamepadBrand.playstation);
  });

  testWidgets(
      'Nintendo Switch brand icons keep ABXY physical swap (.a -> B icon, '
      '.b -> A icon)', (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpGamepadView(tester, registry, ShortcutScope.reader,
        brand: GamepadBrand.nintendoSwitch);

    // The Kenney Switch icons keep the physical A/B, X/Y position swap that the
    // glyph layer established: logical .a shows the physical 'B' icon, etc.
    expectButtonAsset(
        tester, 'A', GamepadButton.a, GamepadBrand.nintendoSwitch);
    expectButtonAsset(
        tester, 'B', GamepadButton.b, GamepadBrand.nintendoSwitch);
    expectButtonAsset(
        tester, 'X', GamepadButton.x, GamepadBrand.nintendoSwitch);
    expectButtonAsset(
        tester, 'Y', GamepadButton.y, GamepadBrand.nintendoSwitch);
    // Pin the swap explicitly at the asset level.
    expect(
      GamepadButtonAssets.assetFor(
          GamepadButton.a, GamepadBrand.nintendoSwitch),
      endsWith('switch_button_b.png'),
    );
    expect(
      GamepadButtonAssets.assetFor(
          GamepadButton.b, GamepadBrand.nintendoSwitch),
      endsWith('switch_button_a.png'),
    );
  });

  testWidgets('a bound gamepad button is tappable and routes onGamepadTap',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    // Seed a gamepad binding so its knob is bound + tappable.
    registry.updateBinding(
      ShortcutAction.readerToggleFurigana,
      const ShortcutBindingSet(
        gamepadBindings: <GamepadBinding>[GamepadBinding(GamepadButton.a)],
      ),
    );
    GamepadButton? tappedButton;
    await pumpGamepadView(
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
    await pumpGamepadView(
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
    await pumpKeyboardView(
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
    await pumpKeyboardView(tester, registry, ShortcutScope.reader);
    final Finder f9InkWell = find.descendant(
      of: find.byKey(Key('keycap_${LogicalKeyboardKey.f9.keyId}')),
      matching: find.byType(InkWell),
    );
    expect(f9InkWell, findsNothing);
  });
}
