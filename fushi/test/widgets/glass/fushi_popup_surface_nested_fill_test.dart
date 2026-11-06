import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
    FushiGlassMaterial? material,
  }) {
    final ThemeData data = buildFushiThemeData(
      scheme: ColorScheme.fromSeed(
        seedColor: Colors.teal,
        brightness: brightness,
      ),
      textTheme: Typography.material2021().black,
      glass:
          material ??
          (glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off),
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
    testWidgets('MD3 真模糊（$brightness）：BackdropFilter + 填充 97%（实底）', (
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
      // 2026-10-06：MD3 查词面板内容区要读作实底（背后正文不可读），两种明暗同 97%。
      expect(fill.color.a, closeTo(0.97, 0.005));
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

    // 反馈 hQpYQyWJNQ：透明度不被允许时 iOS / macOS 的实底也必须是原生平台视图。
    // Flutter 画的实底（ColoredBox）在嵌套层上会被 iOS 引擎的平台视图合成规则吞掉：
    // 它画在父层 WebView 之后，只在与父层重叠处可见，压在阅读器正文上的部分整块透明
    // （iOS 26.5 模拟器最小复现实测，截图与反馈一致）。断言背衬是带不透明 solidColor
    // 的原生视图，且 surface 里没有任何 Flutter 画的不透明面板。
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      for (final ({String label, bool glass, bool reduce, bool highContrast}) c
          in <({String label, bool glass, bool reduce, bool highContrast})>[
            (
              label: 'Apple 材质档 off',
              glass: true,
              reduce: false,
              highContrast: false,
            ),
            (
              label: 'MD3 系统降低透明度',
              glass: false,
              reduce: true,
              highContrast: false,
            ),
            (
              label: 'Apple 高对比度',
              glass: true,
              reduce: false,
              highContrast: true,
            ),
          ]) {
        testWidgets('${platform.name} ${c.label}：实底是原生视图，不是 Flutter 面板', (
          WidgetTester tester,
        ) async {
          SystemTransparency.reduceTransparency.value = c.reduce;
          await tester.pumpWidget(
            host(
              theme(
                glass: c.glass,
                brightness: Brightness.dark,
                platform: platform,
                material: c.glass && !c.highContrast
                    ? FushiGlassMaterial.off
                    : null,
              ),
              const FushiPopupSurface(
                borderOnForeground: false,
                child: SizedBox.expand(),
              ),
              highContrast: c.highContrast,
            ),
          );
          tester.takeException();
          final FushiNativeMaterialBackdrop b = tester
              .widget<FushiNativeMaterialBackdrop>(
                inSurface(FushiNativeMaterialBackdrop),
              );
          expect(b.solidColor, isNotNull, reason: '实底必须由原生视图画');
          expect(b.solidColor!.a, 1.0);
          expect(b.tint, isNull);
          expect(
            tester
                .widgetList<ColoredBox>(inSurface(ColoredBox))
                .where((ColoredBox box) => box.color.a == 1.0),
            isEmpty,
            reason: 'Flutter 画的实底在嵌套层压在正文上的部分会整块透明',
          );
          expect(inSurface(BackdropFilter), findsNothing);
        });
      }
    }

    testWidgets('材质可用时不带 solidColor（仍是真模糊）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          theme(glass: true, platform: TargetPlatform.iOS),
          const FushiPopupSurface(
            borderOnForeground: false,
            child: SizedBox.expand(),
          ),
        ),
      );
      tester.takeException();
      expect(
        tester
            .widget<FushiNativeMaterialBackdrop>(
              inSurface(FushiNativeMaterialBackdrop),
            )
            .solidColor,
        isNull,
      );
    });

    // 反馈 hQpYQyWJNQ 的合成规则（见 fushiNativePopupBackdropHostAvailable）：父层
    // 查词 WebView 带圆角裁剪，紧跟它之后绘制的 Flutter 内容在 iOS 上被裁成父层形状，
    // 压在正文上的部分不显示。嵌套层因此必须**先**画原生背衬：surface 里任何会出像素
    // 的 Flutter 绘制（外侧投影、描边、实底……）都只能排在原生背衬之后。
    bool paintsPixels(RenderObject o) {
      if (o is RenderCustomPaint) {
        return o.painter != null || o.foregroundPainter != null;
      }
      if (o is RenderDecoratedBox || o is RenderParagraph || o is RenderImage) {
        return true;
      }
      if (o is RenderPhysicalShape) return o.color.a > 0 || o.elevation > 0;
      if (o is RenderPhysicalModel) return o.color.a > 0 || o.elevation > 0;
      return o.runtimeType.toString() == '_RenderColoredBox';
    }

    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      for (final ({String label, bool glass, FushiGlassMaterial? material}) c
          in <({String label, bool glass, FushiGlassMaterial? material})>[
            (label: 'Apple 系统材质', glass: true, material: null),
            (
              label: 'Apple 原生实底',
              glass: true,
              material: FushiGlassMaterial.off,
            ),
            (label: 'MD3 系统材质', glass: false, material: null),
          ]) {
        testWidgets('${platform.name} ${c.label}：原生背衬是 surface 里第一个绘制的东西', (
          WidgetTester tester,
        ) async {
          await tester.pumpWidget(
            host(
              theme(
                glass: c.glass,
                brightness: Brightness.dark,
                platform: platform,
                material: c.material,
              ),
              const FushiPopupSurface(
                borderOnForeground: false,
                child: SizedBox.expand(),
              ),
            ),
          );
          tester.takeException();
          final RenderObject backdropRender = tester.renderObject(
            inSurface(FushiNativeMaterialBackdrop),
          );
          final List<RenderObject> paintOrder = <RenderObject>[];
          void visit(RenderObject o) {
            paintOrder.add(o);
            o.visitChildren(visit);
          }

          visit(tester.renderObject(find.byType(FushiPopupSurface)));
          final int backdropAt = paintOrder.indexOf(backdropRender);
          expect(backdropAt, isNonNegative);
          expect(
            paintOrder.take(backdropAt).where(paintsPixels).toList(),
            isEmpty,
            reason: '排在原生背衬之前的 Flutter 绘制在嵌套层上压在正文上的部分会消失',
          );
          expect(
            paintOrder
                .skip(backdropAt)
                .whereType<RenderCustomPaint>()
                .any((RenderCustomPaint p) => p.painter != null),
            isTrue,
            reason: '外侧投影仍要画（排在原生背衬之后）',
          );
        });
      }
    }

    // 投影挪到原生背衬之上后，形状内侧一个像素都不能碰（否则压暗面板），形状外侧照画。
    for (final bool glass in <bool>[true, false]) {
      testWidgets('外侧投影只画在面板形状外（${glass ? 'Apple' : 'MD3'}）', (
        WidgetTester tester,
      ) async {
        // 原生背衬的平台视图创建要能成功：失败的异常会在 runAsync 里异步抛出。
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          (MethodCall call) async => null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform_views,
            null,
          ),
        );
        final GlobalKey boundaryKey = GlobalKey();
        await tester.pumpWidget(
          host(
            theme(
              glass: glass,
              brightness: Brightness.dark,
              platform: TargetPlatform.iOS,
            ),
            RepaintBoundary(
              key: boundaryKey,
              child: const Padding(
                padding: EdgeInsets.all(40),
                child: FushiPopupSurface(
                  borderOnForeground: false,
                  showBorder: false,
                  child: SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        final RenderRepaintBoundary boundary = tester
            .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
        final (ByteData, int)? captured = await tester.runAsync(() async {
          final ui.Image image = await boundary.toImage();
          final ByteData? data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final int w = image.width;
          image.dispose();
          return (data!, w);
        });
        final (ByteData data, int w) = captured!;
        int alphaAt(int x, int y) => data.getUint8((y * w + x) * 4 + 3);
        // host 给 240×180，内缩 40 后面板是 160×100，位于 (40,40)-(200,140)。
        expect(alphaAt(120, 90), 0, reason: '面板正中不该有投影');
        expect(alphaAt(120, 138), 0, reason: '面板底边内侧不该有投影');
        expect(alphaAt(120, 146), greaterThan(0), reason: '面板下方要有外侧投影');
      });
    }
  });

  // BUG-3225：app 外查词窗（popup_dictionary_page）的整卡由外层 standaloneWindow
  // surface 画，基础层 DictionaryPopupLayer 传 `Colors.transparent` 让外层卡面透出来。
  // 面板背衬曾把它 `.withValues(alpha: 1)` 压成不透明——透明黑变纯黑，Android（采
  // 不到模糊、恒实底）上词条区整块黑底，浅色主题的深色词头 / 频率 / 音调看不见。
  // 这里按真实像素断言：透明内层下读到的必须是外层卡面色，不是黑。
  group('显式透明填充的内层不画面板（BUG-3225）', () {
    const Color outerCard = Color(0xFFFFF8EC);

    Future<Color> innerPixel(
      WidgetTester tester, {
      required bool glass,
      required Brightness brightness,
      required TargetPlatform platform,
    }) async {
      final GlobalKey boundaryKey = GlobalKey();
      await tester.pumpWidget(
        host(
          theme(glass: glass, brightness: brightness, platform: platform),
          RepaintBoundary(
            key: boundaryKey,
            child: const FushiPopupSurface(
              standaloneWindow: true,
              color: outerCard,
              showBorder: false,
              child: Padding(
                padding: EdgeInsets.all(20),
                child: FushiPopupSurface(
                  color: Colors.transparent,
                  showBorder: false,
                  borderOnForeground: false,
                  child: SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      );
      final RenderRepaintBoundary boundary = tester
          .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
      final ByteData bytes = (await tester
          .runAsync(() async {
            final ui.Image image = await boundary.toImage();
            final ByteData? data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final int w = image.width;
            final int h = image.height;
            image.dispose();
            return (data!, w, h);
          })
          .then(((ByteData, int, int)? r) {
            final (ByteData data, int w, int h) = r!;
            // 取内层正中央的像素。
            final int offset = ((h ~/ 2) * w + (w ~/ 2)) * 4;
            return ByteData.sublistView(data, offset, offset + 4);
          }));
      return Color.fromARGB(
        bytes.getUint8(3),
        bytes.getUint8(0),
        bytes.getUint8(1),
        bytes.getUint8(2),
      );
    }

    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.windows,
    ]) {
      for (final bool glass in <bool>[false, true]) {
        for (final Brightness brightness in Brightness.values) {
          testWidgets('${platform.name} ${glass ? 'Apple' : 'MD3'} $brightness：'
              '透明内层透出外层卡面', (WidgetTester tester) async {
            final Color pixel = await innerPixel(
              tester,
              glass: glass,
              brightness: brightness,
              platform: platform,
            );
            expect(pixel, outerCard, reason: '内层透明填充被画成了不透明面板（BUG-3225 黑底）');
            expect(inSurface(BackdropFilter), findsNothing);
          });
        }
      }
    }
  });
}
