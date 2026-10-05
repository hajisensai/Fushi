import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_native_material.dart';
import 'package:fushi/src/utils/system_transparency.dart';

// 查词面板（装平台视图的 FushiPopupSurface）的不透明度分档：
// - 能真模糊：面板色 亮 90% / 暗 88% + 模糊（MD3 的玻璃材质档恒为 off，不能拿它当
//   「关透明」的判据——那会让 MD3 查词框在 Windows 上永远是实底；Android 的 WebView
//   是 Hybrid Composition、采不到模糊，恒实底）；
// - 系统降低透明度 / 高对比度：实底；
// - iOS / macOS：WebView 下垫原生系统材质（NSVisualEffectView / UIVisualEffectView），
//   嵌套层与第一层同一材质 / 色层。
void main() {
  ThemeData theme({
    required bool glass,
    Brightness brightness = Brightness.light,
    // 默认钉 Windows：flutter test 默认平台是 Android，而 Android 阅读器 WebView 是
    // Hybrid Composition、查词面板恒不透明（fushiPopupBackdropSampleable）。
    TargetPlatform? platform = TargetPlatform.windows,
  }) {
    final ThemeData data = buildFushiThemeData(
      scheme: ColorScheme.fromSeed(
        seedColor: Colors.teal,
        brightness: brightness,
      ),
      textTheme: Typography.material2021().black,
      glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
      glassDesign: glass,
    );
    return platform == null ? data : data.copyWith(platform: platform);
  }

  Widget host(ThemeData data, Widget child, {bool highContrast = false}) =>
      MaterialApp(
        theme: data,
        themeAnimationDuration: Duration.zero,
        home: MediaQuery(
          data: MediaQueryData(highContrast: highContrast),
          child: FushiGlassScope(
            child: Scaffold(
              body: Center(
                child: SizedBox(width: 240, height: 180, child: child),
              ),
            ),
          ),
        ),
      );

  Finder inSurface(Type t) => find.descendant(
    of: find.byType(FushiPopupSurface),
    matching: find.byType(t),
  );

  const Widget surface = FushiPopupSurface(
    borderOnForeground: false,
    child: SizedBox.expand(),
  );

  tearDown(() => SystemTransparency.reduceTransparency.value = false);

  for (final Brightness brightness in Brightness.values) {
    testWidgets('MD3 真模糊（$brightness）：BackdropFilter + 填充 90% / 88%', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(theme(glass: false, brightness: brightness), surface),
      );
      expect(inSurface(BackdropFilter), findsOneWidget);
      final ColoredBox fill = tester.widget<ColoredBox>(
        find.descendant(
          of: inSurface(BackdropFilter),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(
        fill.color.a,
        closeTo(brightness == Brightness.dark ? 0.88 : 0.9, 0.005),
      );
    });
  }

  testWidgets('每一层查词浮层的 BackdropFilter 都进同一个背景快照组', (
    WidgetTester tester,
  ) async {
    // 第一层 + 嵌套层叠放（与宿主 Stack 同形）：每层的模糊都必须带同一个
    // backdropGroupKey，Impeller 下子层才模糊正文、而不是下面那层查词卡。
    for (final bool glass in <bool>[false, true]) {
      final ThemeData data = glass
          ? buildFushiThemeData(
              scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              textTheme: Typography.material2021().black,
              glass: FushiGlassMaterial.frosted,
              glassDesign: true,
            ).copyWith(platform: TargetPlatform.windows)
          : theme(glass: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: data,
          themeAnimationDuration: Duration.zero,
          home: const Scaffold(
            body: Stack(
              children: <Widget>[
                Positioned(
                  left: 0,
                  top: 0,
                  width: 240,
                  height: 180,
                  child: surface,
                ),
                Positioned(
                  left: 60,
                  top: 40,
                  width: 240,
                  height: 180,
                  child: surface,
                ),
              ],
            ),
          ),
        ),
      );
      final List<BackdropFilter> filters = tester
          .widgetList<BackdropFilter>(inSurface(BackdropFilter))
          .toList();
      expect(filters, hasLength(2), reason: 'glass=$glass');
      for (final BackdropFilter f in filters) {
        expect(
          f.backdropGroupKey,
          same(kFushiLookupPopupBackdropKey),
          reason: 'glass=$glass',
        );
      }
    }
  });

  testWidgets('系统降低透明度 / 高对比度：实底、无模糊', (WidgetTester tester) async {
    SystemTransparency.reduceTransparency.value = true;
    await tester.pumpWidget(host(theme(glass: false), surface));
    expect(inSurface(BackdropFilter), findsNothing);
    expect(
      tester
          .widgetList<ColoredBox>(inSurface(ColoredBox))
          .any((ColoredBox b) => b.color.a == 1.0),
      isTrue,
    );

    SystemTransparency.reduceTransparency.value = false;
    await tester.pumpWidget(
      host(theme(glass: false), surface, highContrast: true),
    );
    await tester.pump();
    expect(inSurface(BackdropFilter), findsNothing);
  });

  test('嵌套层与第一层同一材质：宿主与 surface 都没有按层区分填充的参数', () {
    // 用户 2026-10-05 拍板：每一层嵌套查词与第一层完全同一观感（同一模糊、同一
    // 填充 / 色层）。曾有的 nestedLayer「≥ 88% 可读性下限」已撤掉——Mac「嵌套太
    // 透明」的根因是没有真模糊，原生系统材质落地后嵌套层自然同样有材质。
    for (final String path in <String>[
      'lib/src/pages/base_source_page.dart',
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
      'lib/src/pages/implementations/dictionary_popup_layer.dart',
      'lib/src/utils/components/fushi_material_components.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        isNot(contains('nestedLayer')),
        reason: '$path 又出现了按层区分的填充参数',
      );
    }
  });

  group('iOS / macOS 原生系统材质', () {
    late bool Function() saved;
    setUp(() {
      saved = debugNativeMaterialHostSupported;
      debugNativeMaterialHostSupported = () => true;
    });
    tearDown(() => debugNativeMaterialHostSupported = saved);

    Future<FushiNativeMaterialBackdrop> backdrop(
      WidgetTester tester, {
      required bool glass,
      required Brightness brightness,
      Color? color,
    }) async {
      await tester.pumpWidget(
        host(
          theme(
            glass: glass,
            brightness: brightness,
            platform: TargetPlatform.macOS,
          ),
          FushiPopupSurface(
            borderOnForeground: false,
            color: color,
            child: const SizedBox.expand(),
          ),
        ),
      );
      // 测试宿主没有原生材质工厂：平台视图创建失败与本断言无关。
      tester.takeException();
      return tester.widget<FushiNativeMaterialBackdrop>(
        inSurface(FushiNativeMaterialBackdrop),
      );
    }

    for (final Brightness brightness in Brightness.values) {
      testWidgets('MD3（$brightness）：材质 + 0.38–0.42 面板色淡染', (
        WidgetTester tester,
      ) async {
        final FushiNativeMaterialBackdrop b = await backdrop(
          tester,
          glass: false,
          brightness: brightness,
        );
        expect(b.tint, isNotNull);
        expect(b.tint!.a, inInclusiveRange(0.37, 0.43));
        expect(b.dark, brightness == Brightness.dark);
      });
    }

    testWidgets('玻璃设计系统：默认纯系统材质；手动词典底色才淡染', (WidgetTester tester) async {
      expect(
        (await backdrop(tester, glass: true, brightness: Brightness.dark)).tint,
        isNull,
      );
      final FushiNativeMaterialBackdrop tinted = await backdrop(
        tester,
        glass: true,
        brightness: Brightness.dark,
        color: Colors.blueGrey,
      );
      expect(tinted.tint, isNotNull);
      expect(tinted.tint!.a, lessThan(0.88));
    });
  });
}
