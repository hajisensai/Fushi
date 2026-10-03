import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

// 毛玻璃材质（偏好 `glass_material`）第一阶段契约：
// - 偏好值解析容错、主题工厂把材质注入 [FushiGlassTheme]；
// - 墨水屏 / 系统增强对比度 / 缺扩展一律回退实心（半透明在墨水屏上是抖动残影，
//   增强对比度是用户明确要求的可读性）；
// - 功能层表面（对话框 / 底栏）只在 frosted 下才挂 BackdropFilter——off 时
//   不得多出一层模糊合成（性能 + 与改造前像素一致）；
// - 查词弹窗主题永远不带玻璃（它的底色必须不透明，见 popup_surface_opaque_guard）。
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
    expect(FushiGlassMaterial.fromPrefValue('liquid'), FushiGlassMaterial.off);
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
    expect(tester.widget<Dialog>(find.byType(Dialog)).backgroundColor, isNull);
  });

  testWidgets('FushiDialogFrame turns translucent when frosted', (
    WidgetTester tester,
  ) async {
    await pumpDialog(tester, theme(glass: FushiGlassMaterial.frosted));
    expect(hasBlur(tester), isTrue);
    expect(
      tester.widget<Dialog>(find.byType(Dialog)).backgroundColor,
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
    expect(
      tester.widget<Material>(find.byKey(fushiMaterialNavKey)).color,
      Colors.transparent,
    );
    expect(tester.getRect(find.byKey(fushiMaterialNavKey)), solid);
  });

  test('dictionary popup theme never opts into glass', () {
    final String source = File(
      'lib/src/pages/implementations/dictionary_popup_theme.dart',
    ).readAsStringSync();
    expect(source, contains('buildFushiThemeData('));
    expect(source.contains('glass:'), isFalse);
  });
}
