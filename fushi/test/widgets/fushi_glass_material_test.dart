import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_theme.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../helpers/glass_unwrap.dart';

// 毛玻璃材质（偏好 `glass_material`）第一阶段契约：
// - 偏好值解析容错、主题工厂把材质注入 [FushiGlassTheme]；
// - 墨水屏 / 系统增强对比度 / 缺扩展一律回退实心（半透明在墨水屏上是抖动残影，
//   增强对比度是用户明确要求的可读性）；
// - 功能层表面（对话框 / 底栏）只在 frosted 下才挂 BackdropFilter——off 时
//   不得多出一层模糊合成（性能 + 与改造前像素一致）；
// - 查词弹窗主题跟随玻璃材质，但弹窗底色恒不透明（见 popup_surface_opaque_guard），
//   墨水屏下不带玻璃。
void main() {
  ThemeData theme({
    FushiGlassMaterial glass = FushiGlassMaterial.off,
    bool eink = false,
    Brightness brightness = Brightness.light,
  }) =>
      buildFushiThemeData(
        scheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: brightness,
        ),
        textTheme: Typography.material2021().black,
        eink: eink,
        glass: glass,
      );

  Future<FushiGlassMaterial> resolve(
    WidgetTester tester,
    ThemeData data, {
    bool highContrast = false,
  }) async {
    late FushiGlassMaterial resolved;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(highContrast: highContrast),
        child: Theme(
          data: data,
          child: Builder(
            builder: (BuildContext context) {
              resolved = glassMaterialOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return resolved;
  }

  bool hasBlur(WidgetTester tester) => tester
      .widgetList<BackdropFilter>(find.byType(BackdropFilter))
      .any((BackdropFilter f) => f.filter is ImageFilter);

  test('fromPrefValue parses known values and falls back to off', () {
    expect(FushiGlassMaterial.fromPrefValue('frosted'),
        FushiGlassMaterial.frosted);
    expect(FushiGlassMaterial.fromPrefValue('off'), FushiGlassMaterial.off);
    expect(FushiGlassMaterial.fromPrefValue(null), FushiGlassMaterial.off);
    expect(
        FushiGlassMaterial.fromPrefValue('liquid'), FushiGlassMaterial.liquid);
    expect(FushiGlassMaterial.fromPrefValue('bogus'), FushiGlassMaterial.off);
  });

  test('buildFushiThemeData injects the glass extension', () {
    expect(
      theme(glass: FushiGlassMaterial.frosted)
          .extension<FushiGlassTheme>()
          ?.material,
      FushiGlassMaterial.frosted,
    );
    expect(
      theme().extension<FushiGlassTheme>()?.material,
      FushiGlassMaterial.off,
    );
  });

  testWidgets('glassMaterialOf honours frosted on a plain theme', (
    WidgetTester tester,
  ) async {
    expect(
      await resolve(tester, theme(glass: FushiGlassMaterial.frosted)),
      FushiGlassMaterial.frosted,
    );
  });

  group('liquid', () {
    late bool Function() original;
    setUp(() => original = debugShaderFilterSupported);
    tearDown(() => debugShaderFilterSupported = original);

    testWidgets('stays liquid when the engine supports shader filters', (
      WidgetTester tester,
    ) async {
      debugShaderFilterSupported = () => true;
      expect(
        await resolve(tester, theme(glass: FushiGlassMaterial.liquid)),
        FushiGlassMaterial.liquid,
      );
    });

    testWidgets('degrades to frosted without shader filter support', (
      WidgetTester tester,
    ) async {
      debugShaderFilterSupported = () => false;
      expect(
        await resolve(tester, theme(glass: FushiGlassMaterial.liquid)),
        FushiGlassMaterial.frosted,
      );
    });

    testWidgets('still falls back to off under e-ink', (
      WidgetTester tester,
    ) async {
      debugShaderFilterSupported = () => true;
      expect(
        await resolve(
          tester,
          theme(glass: FushiGlassMaterial.liquid, eink: true),
        ),
        FushiGlassMaterial.off,
      );
    });

    testWidgets('FushiGlassSurface renders the liquid shader container', (
      WidgetTester tester,
    ) async {
      debugShaderFilterSupported = () => true;
      await tester.pumpWidget(
        Theme(
          data: theme(glass: FushiGlassMaterial.liquid),
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: FushiGlassSurface(
              borderRadius: BorderRadius.all(Radius.circular(16)),
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );
      expect(find.byType(GlassContainer), findsOneWidget);
      expect(hasBlur(tester), isFalse);
    });
  });

  testWidgets('glassMaterialOf falls back to off under e-ink', (
    WidgetTester tester,
  ) async {
    expect(
      await resolve(
        tester,
        theme(glass: FushiGlassMaterial.frosted, eink: true),
      ),
      FushiGlassMaterial.off,
    );
  });

  testWidgets('glassMaterialOf falls back to off with high contrast', (
    WidgetTester tester,
  ) async {
    expect(
      await resolve(
        tester,
        theme(glass: FushiGlassMaterial.frosted),
        highContrast: true,
      ),
      FushiGlassMaterial.off,
    );
  });

  testWidgets('glassMaterialOf is off without the extension', (
    WidgetTester tester,
  ) async {
    expect(await resolve(tester, ThemeData()), FushiGlassMaterial.off);
  });

  testWidgets('FushiGlassSurface blurs only when frosted', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      Theme(
        data: theme(),
        child: const FushiGlassSurface(child: SizedBox(width: 10, height: 10)),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);

    await tester.pumpWidget(
      Theme(
        data: theme(glass: FushiGlassMaterial.frosted),
        child: const FushiGlassSurface(child: SizedBox(width: 10, height: 10)),
      ),
    );
    expect(hasBlur(tester), isTrue);
    final DecoratedBox fill = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(BackdropFilter),
        matching: find.byType(DecoratedBox),
      ),
    );
    final Color fillColor = (fill.decoration as BoxDecoration).color!;
    expect(fillColor.a, closeTo(fushiGlassFillOpacity(Brightness.light), 1e-3));
  });

  Future<void> pumpDialog(WidgetTester tester, ThemeData data) =>
      tester.pumpWidget(
        MaterialApp(
          theme: data,
          home: const Scaffold(
            body: FushiDialogFrame(child: Text('Dialog body')),
          ),
        ),
      );

  testWidgets('FushiDialogFrame is solid when glass is off', (
    WidgetTester tester,
  ) async {
    await pumpDialog(tester, theme());
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.widget<Dialog>(glassUnwrap<Dialog>(find.byType(Dialog))).backgroundColor, isNull);
  });

  testWidgets('FushiDialogFrame turns translucent when frosted', (
    WidgetTester tester,
  ) async {
    await pumpDialog(tester, theme(glass: FushiGlassMaterial.frosted));
    expect(hasBlur(tester), isTrue);
    expect(
      tester.widget<Dialog>(glassUnwrap<Dialog>(find.byType(Dialog))).backgroundColor,
      Colors.transparent,
    );
    expect(find.text('Dialog body'), findsOneWidget);
  });

  Future<void> pumpBar(WidgetTester tester, ThemeData data) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: data,
        home: FushiFocusRoot(
          child: Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: Builder(
              builder: (BuildContext context) => adaptiveBottomBar(
                context: context,
                currentIndex: 0,
                onTap: (_) {},
                items: const <AdaptiveNavItem>[
                  AdaptiveNavItem(icon: Icons.book, label: 'Books'),
                  AdaptiveNavItem(icon: Icons.search, label: 'Dict'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('bottom bar blurs only when frosted and keeps its geometry', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester, theme());
    expect(find.byType(BackdropFilter), findsNothing);
    final Rect solid = tester.getRect(find.byKey(fushiMaterialNavKey));

    await pumpBar(tester, theme(glass: FushiGlassMaterial.frosted));
    expect(hasBlur(tester), isTrue);
    // M3E 悬浮导航：带 key 的 Material 恒为透明层（不画底色），底色 / 模糊
    // 画在悬浮胶囊上。
    expect(
      tester.widget<Material>(find.byKey(fushiMaterialNavKey)).type,
      MaterialType.transparency,
    );
    expect(tester.getRect(find.byKey(fushiMaterialNavKey)), solid);
  });

  // 重设计后查词弹窗主题跟随 app 的玻璃材质 / 设计系统（组件表面同源），但
  // 弹窗自己的底色（fillColor）必须恒不透明，墨水屏下玻璃一律关掉。
  test('dictionary popup fill stays opaque; e-ink strips glass', () {
    DictionaryPopupTheme resolvePopup({
      required bool eink,
      bool glassDesign = false,
    }) => resolveDictionaryPopupTheme(
      eink: eink,
      einkDark: false,
      readerBackground: const Color(0xFFF7F1E3),
      readerForeground: const Color(0xFF222222),
      readerDark: false,
      buildColorScheme: (Brightness b) =>
          ColorScheme.fromSeed(seedColor: Colors.teal, brightness: b),
      textTheme: Typography.material2021().black,
      glassDesign: glassDesign,
      glass: FushiGlassMaterial.frosted,
    );

    for (final bool glassDesign in <bool>[false, true]) {
      final DictionaryPopupTheme glassy = resolvePopup(
        eink: false,
        glassDesign: glassDesign,
      );
      expect(glassy.fillColor.a, 1);
    }
    final DictionaryPopupTheme eink = resolvePopup(eink: true);
    expect(eink.fillColor, Colors.white);
    expect(
      eink.theme.extension<FushiGlassTheme>()?.material ??
          FushiGlassMaterial.off,
      FushiGlassMaterial.off,
    );
    expect(eink.theme.dialogTheme.backgroundColor!.a, 1);
  });
  group('component-wide glass theme', () {
    double alphaOf(Color? c) => c!.a;

    test('glass tints every Flutter-built surface translucent', () {
      final ThemeData t = theme(glass: FushiGlassMaterial.frosted);
      expect(alphaOf(t.dialogTheme.backgroundColor), lessThan(1));
      expect(alphaOf(t.popupMenuTheme.color), lessThan(1));
      expect(
        alphaOf(t.menuTheme.style!.backgroundColor!.resolve(<WidgetState>{})),
        lessThan(1),
      );
      expect(
        alphaOf(
          t.dropdownMenuTheme.menuStyle!.backgroundColor!
              .resolve(<WidgetState>{}),
        ),
        lessThan(1),
      );
      expect(alphaOf(t.bottomSheetTheme.backgroundColor), lessThan(1));
      expect(alphaOf(t.snackBarTheme.backgroundColor), lessThan(1));
      expect(alphaOf(t.cardTheme.color), lessThan(1));
      expect(alphaOf(t.drawerTheme.backgroundColor), lessThan(1));
      expect(alphaOf(t.navigationBarTheme.backgroundColor), lessThan(1));
      expect(
        alphaOf((t.tooltipTheme.decoration! as BoxDecoration).color),
        lessThan(1),
      );
      expect(t.appBarTheme.backgroundColor, Colors.transparent);
      expect(t.floatingActionButtonTheme.backgroundColor, Colors.transparent);
    });

    // 玻璃关 / 墨水屏：MD3 组件主题照常给出实色面板（重设计后不再留 null 交给
    // Flutter 默认），但绝不出现玻璃的半透明染色——null 或不透明都算实心。
    void expectSolid(Color? c) {
      if (c != null) expect(c.a, 1);
    }

    void expectSolidComponentSurfaces(ThemeData t) {
      final ColorScheme cs = t.colorScheme;
      expect(t.dialogTheme.backgroundColor, cs.surfaceContainerHigh);
      expect(t.popupMenuTheme.color, cs.surfaceContainer);
      expect(
        t.menuTheme.style!.backgroundColor!.resolve(<WidgetState>{}),
        cs.surfaceContainer,
      );
      expectSolid(t.bottomSheetTheme.backgroundColor);
      expectSolid(t.bottomSheetTheme.modalBackgroundColor);
      expectSolid(t.snackBarTheme.backgroundColor);
      expect(t.appBarTheme.backgroundColor, isNot(Colors.transparent));
      expect(alphaOf(t.cardTheme.color), 1);
    }

    test('glass off keeps the stock solid component theme', () {
      final ThemeData t = theme();
      expectSolidComponentSurfaces(t);
      expect(t.floatingActionButtonTheme.backgroundColor,
          t.colorScheme.primaryContainer);
    });

    test('e-ink never tints component surfaces', () {
      final ThemeData t = theme(glass: FushiGlassMaterial.frosted, eink: true);
      expectSolidComponentSurfaces(t);
    });

    test('glass panels are translucent but the page stays solid', () {
      final ColorScheme cs = ColorScheme.fromSeed(seedColor: Colors.teal);
      final FushiSurfaceColors glass =
          FushiSurfaceColors.fromScheme(cs, glass: true);
      final FushiSurfaceColors solid = FushiSurfaceColors.fromScheme(cs);
      expect(glass.page.a, 1);
      for (final Color c in <Color>[
        glass.group,
        glass.card,
        glass.search,
        glass.overlay,
      ]) {
        expect(c.a, lessThan(1));
      }
      for (final Color c in <Color>[
        solid.group,
        solid.card,
        solid.search,
        solid.overlay,
      ]) {
        expect(c.a, 1);
      }
    });

    Future<void> openDialog(WidgetTester tester, ThemeData data) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: data,
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showAppDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(content: Text('hi')),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('hi'), findsOneWidget);
    }

    testWidgets('showAppDialog blurs behind the dialog only under glass', (
      WidgetTester tester,
    ) async {
      await openDialog(tester, theme(glass: FushiGlassMaterial.frosted));
      expect(find.byType(FushiGlassDialogBackdrop), findsOneWidget);
      expect(hasBlur(tester), isTrue);
      final Rect glassRect = tester.getRect(find.byType(AlertDialog));

      await openDialog(tester, theme());
      expect(hasBlur(tester), isFalse);
      // passthrough：包装不改变对话框本身的布局。
      expect(tester.getRect(find.byType(AlertDialog).last), glassRect);
    });

    testWidgets('FushiGlassFab paints glass only when the theme clears the FAB',
        (WidgetTester tester) async {
      Future<void> pump(ThemeData data) => tester.pumpWidget(
            MaterialApp(
              theme: data,
              home: Scaffold(
                floatingActionButton: FushiGlassFab(
                  child: FloatingActionButton(
                    onPressed: () {},
                    child: const Icon(Icons.add),
                  ),
                ),
              ),
            ),
          );
      await pump(theme());
      expect(find.byType(FushiGlassSurface), findsNothing);

      await pump(theme(glass: FushiGlassMaterial.frosted));
      // MaterialApp 换主题走 AnimatedTheme 插值，等它落定。
      await tester.pumpAndSettle();
      expect(find.byType(FushiGlassSurface), findsOneWidget);
      expect(hasBlur(tester), isTrue);
    });
  });
}
