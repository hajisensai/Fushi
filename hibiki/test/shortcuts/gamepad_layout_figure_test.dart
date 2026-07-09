import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_button_widget.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_button_assets.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_layout_view.dart';

/// TODO-942 P1：整张真实布局手柄图。
///
/// 纯函数 `buildGamepadFigure` 钉住：17 按钮全出现无重复、归一化坐标 0..1、
/// 品牌位置差异（Xbox/Switch 十字键左下 vs PS 十字键左上）。
/// widget 层钉住：bound 高亮、tap/emptyTap 路由、窄屏横向滚动无溢出。
void main() {
  group('buildGamepadFigure (pure data table)', () {
    for (final GamepadBrand brand in GamepadBrand.values) {
      test('$brand: all 17 GamepadButton values appear exactly once', () {
        final List<GamepadPadSpec> specs = buildGamepadFigure(brand);
        final List<GamepadButton> buttons =
            specs.map((GamepadPadSpec s) => s.button).toList();
        expect(buttons.length, GamepadButton.values.length,
            reason: 'figure must place every button exactly once');
        expect(buttons.toSet(), GamepadButton.values.toSet(),
            reason: 'figure must cover the full enum, no dupes/misses');
      });

      test('$brand: all centers are normalized within 0..1', () {
        for (final GamepadPadSpec spec in buildGamepadFigure(brand)) {
          expect(spec.center.dx, inInclusiveRange(0, 1),
              reason: '${spec.button} dx out of range');
          expect(spec.center.dy, inInclusiveRange(0, 1),
              reason: '${spec.button} dy out of range');
          expect(spec.size, greaterThan(0));
        }
      });
    }

    GamepadPadSpec specOf(GamepadBrand brand, GamepadButton button) =>
        buildGamepadFigure(brand)
            .firstWhere((GamepadPadSpec s) => s.button == button);

    test('Xbox/Switch place the dpad lower-left, BELOW the left stick', () {
      for (final GamepadBrand brand in <GamepadBrand>[
        GamepadBrand.xbox,
        GamepadBrand.nintendoSwitch,
      ]) {
        final GamepadPadSpec dpadUp = specOf(brand, GamepadButton.dpadUp);
        final GamepadPadSpec stick = specOf(brand, GamepadButton.thumbLeft);
        expect(dpadUp.center.dy, greaterThan(stick.center.dy),
            reason: '$brand: dpad must sit below the left stick');
        expect(dpadUp.center.dx, lessThan(0.5),
            reason: '$brand: dpad cluster stays on the left half');
      }
    });

    test('PlayStation places the dpad upper-left, ABOVE both sticks', () {
      final GamepadPadSpec dpadUp =
          specOf(GamepadBrand.playstation, GamepadButton.dpadUp);
      final GamepadPadSpec left =
          specOf(GamepadBrand.playstation, GamepadButton.thumbLeft);
      final GamepadPadSpec right =
          specOf(GamepadBrand.playstation, GamepadButton.thumbRight);
      expect(dpadUp.center.dy, lessThan(left.center.dy),
          reason: 'PS: dpad sits above the symmetric dual sticks');
      expect(dpadUp.center.dx, lessThan(0.5),
          reason: 'PS: dpad cluster stays on the left half');
      // PS 双摇杆对称居下（Xbox 左摇杆在左上，这里必须不同）。
      expect(left.center.dy, right.center.dy,
          reason: 'PS: dual sticks are symmetric at the same height');
      final GamepadPadSpec xboxStick =
          specOf(GamepadBrand.xbox, GamepadButton.thumbLeft);
      expect(left.center.dy, greaterThan(xboxStick.center.dy),
          reason: 'PS left stick sits lower than the Xbox left stick');
    });

    test('face diamond keeps y top / x left / b right / a bottom on all brands',
        () {
      for (final GamepadBrand brand in GamepadBrand.values) {
        final GamepadPadSpec y = specOf(brand, GamepadButton.y);
        final GamepadPadSpec x = specOf(brand, GamepadButton.x);
        final GamepadPadSpec b = specOf(brand, GamepadButton.b);
        final GamepadPadSpec a = specOf(brand, GamepadButton.a);
        expect(y.center.dy, lessThan(x.center.dy));
        expect(a.center.dy, greaterThan(b.center.dy));
        expect(x.center.dx, lessThan(b.center.dx));
        // 菱形在右半侧（真实手柄面键位置）。
        expect(a.center.dx, greaterThan(0.5));
      }
    });

    test('shoulders/triggers are pills on the top edge', () {
      for (final GamepadBrand brand in GamepadBrand.values) {
        for (final GamepadButton button in <GamepadButton>[
          GamepadButton.lb,
          GamepadButton.rb,
          GamepadButton.lt,
          GamepadButton.rt,
        ]) {
          final GamepadPadSpec spec = specOf(brand, button);
          expect(spec.shape, GamepadPadShape.pill,
              reason: '$button must render as a pill');
          expect(spec.center.dy, lessThan(0.3),
              reason: '$button belongs to the top edge');
        }
      }
    });
  });

  group('GamepadLayoutView (widget)', () {
    setUp(() {
      LocaleSettings.setLocale(AppLocale.en);
    });

    HibikiShortcutRegistry buildRegistry() =>
        HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

    Future<void> pumpView(
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

    testWidgets('renders all 17 keyed buttons in one figure',
        (WidgetTester tester) async {
      final HibikiShortcutRegistry registry = buildRegistry();
      await pumpView(tester, registry, ShortcutScope.reader);
      for (final GamepadButton button in GamepadButton.values) {
        expect(find.byKey(Key('gamepad_btn_${button.label}')), findsOneWidget,
            reason: '${button.label} must appear exactly once on the figure');
      }
    });

    testWidgets(
        'the controller chassis silhouette is painted behind the buttons '
        '(TODO-942 v2)', (WidgetTester tester) async {
      final HibikiShortcutRegistry registry = buildRegistry();
      await pumpView(tester, registry, ShortcutScope.reader);
      // The "后面的手柄图案" the user demanded: a controller-body silhouette
      // drawn behind the button icons. Pin its CustomPainter presence so a
      // refactor cannot silently drop the chassis and regress to bare buttons
      // floating on a rectangle again.
      final Iterable<CustomPaint> paints = tester.widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(GamepadLayoutView),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(
        paints.any((CustomPaint cp) =>
            cp.painter?.runtimeType.toString().contains('GamepadChassis') ??
            false),
        isTrue,
        reason: 'the gamepad figure must render a controller body silhouette '
            'behind the button icons, not leave them on an empty rectangle',
      );
    });

    testWidgets('a bound button renders highlighted (bound=true)',
        (WidgetTester tester) async {
      final HibikiShortcutRegistry registry = buildRegistry();
      registry.updateBinding(
        ShortcutAction.readerToggleBookmark,
        const ShortcutBindingSet(
          gamepadBindings: <GamepadBinding>[GamepadBinding(GamepadButton.a)],
        ),
      );
      await pumpView(tester, registry, ShortcutScope.reader);

      final GamepadButtonWidget aWidget = tester.widget<GamepadButtonWidget>(
        find.byKey(const Key('gamepad_btn_A')),
      );
      expect(aWidget.bound, isTrue, reason: 'seeded binding must highlight A');
      final GamepadButtonWidget modeWidget = tester.widget<GamepadButtonWidget>(
        find.byKey(const Key('gamepad_btn_Mode')),
      );
      expect(modeWidget.bound, isFalse);
    });

    testWidgets('bound tap routes onGamepadTap with the bound actions',
        (WidgetTester tester) async {
      final HibikiShortcutRegistry registry = buildRegistry();
      registry.updateBinding(
        ShortcutAction.readerToggleBookmark,
        const ShortcutBindingSet(
          gamepadBindings: <GamepadBinding>[GamepadBinding(GamepadButton.a)],
        ),
      );
      GamepadButton? tapped;
      List<ShortcutAction>? tappedActions;
      await pumpView(
        tester,
        registry,
        ShortcutScope.reader,
        onGamepadTap: (GamepadButton b, List<ShortcutAction> actions) {
          tapped = b;
          tappedActions = actions;
        },
      );
      await tester.tap(find.byKey(const Key('gamepad_btn_A')));
      await tester.pumpAndSettle();
      expect(tapped, GamepadButton.a);
      expect(tappedActions, contains(ShortcutAction.readerToggleBookmark));
    });

    testWidgets('unbound tap routes onEmptyGamepadTap (key-first assignment)',
        (WidgetTester tester) async {
      final HibikiShortcutRegistry registry = buildRegistry();
      GamepadButton? emptyTapped;
      await pumpView(
        tester,
        registry,
        ShortcutScope.reader,
        onEmptyGamepadTap: (GamepadButton b) => emptyTapped = b,
      );
      await tester.tap(find.byKey(const Key('gamepad_btn_Mode')));
      await tester.pumpAndSettle();
      expect(emptyTapped, GamepadButton.mode);
    });

    testWidgets(
        'narrow screen falls back to a horizontal scroll, no overflow '
        '(TODO-942 P1)', (WidgetTester tester) async {
      final HibikiShortcutRegistry registry = buildRegistry();
      // 320 logical px is below minFigureWidth: the figure must keep its ideal
      // width inside a horizontal scroll instead of squashing/overflowing.
      await pumpView(tester, registry, ShortcutScope.reader,
          surfaceSize: const Size(320, 900));

      expect(tester.takeException(), isNull,
          reason: 'narrow layout must not overflow');
      final Iterable<SingleChildScrollView> scrolls =
          tester.widgetList<SingleChildScrollView>(
              find.byType(SingleChildScrollView));
      expect(
        scrolls.any(
            (SingleChildScrollView s) => s.scrollDirection == Axis.horizontal),
        isTrue,
        reason: 'narrow gamepad figure must add a horizontal scroll fallback',
      );
      // 全部 17 按钮仍在图上。
      for (final GamepadButton button in GamepadButton.values) {
        expect(find.byKey(Key('gamepad_btn_${button.label}')), findsOneWidget);
      }
    });

    testWidgets('brand switch re-skins icons without touching keys',
        (WidgetTester tester) async {
      final HibikiShortcutRegistry registry = buildRegistry();
      await pumpView(tester, registry, ShortcutScope.reader,
          brand: GamepadBrand.playstation);
      // TODO-942: face buttons render the PlayStation Kenney icon (✕ cross),
      // and the Key stays enum-labelled regardless of brand.
      final Image aImage = tester.widget<Image>(
        find.descendant(
          of: find.byKey(const Key('gamepad_btn_A')),
          matching: find.byType(Image),
        ),
      );
      expect(
        (aImage.image as AssetImage).assetName,
        GamepadButtonAssets.assetFor(GamepadButton.a, GamepadBrand.playstation),
      );
    });
  });
}
