import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi/src/utils/components/page_backdrop_layer.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

/// 页面背景预设（2026-10-30）：哪种设计系统 / 预设下画什么，以及设置快照的契约。
void main() {
  late Directory scratch;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('fushi-page-backdrop-');
  });

  tearDown(() {
    pageBackdropSettings.value = const PageBackdropSettings();
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  String writeImage() {
    final File file = File('${scratch.path}/bg.png')
      ..writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);
    return file.path;
  }

  group('PageBackdropSettings', () {
    test('持久化值往返；未知值回默认', () {
      for (final PageBackdropPreset preset in PageBackdropPreset.values) {
        expect(PageBackdropPreset.fromWire(preset.wire), preset);
      }
      expect(PageBackdropPreset.fromWire('dots'), PageBackdropPreset.corner);
      expect(PageBackdropPreset.fromWire(null), PageBackdropPreset.corner);
      expect(PageBackdropStrength.fromWire('x'), PageBackdropStrength.standard);
      expect(PageBackdropBlur.fromWire('x'), PageBackdropBlur.none);
    });

    test('选了自定义却没有图（换设备 / 文件被删）回落到角落形状', () {
      const PageBackdropSettings noImage = PageBackdropSettings(
        preset: PageBackdropPreset.custom,
      );
      expect(noImage.hasCustomImage, isFalse);
      expect(noImage.effectivePreset, PageBackdropPreset.corner);
      expect(noImage.imagePathFor(portrait: false), isNull);
    });

    test('竖屏有单独的图用竖屏图，否则共用横屏图', () {
      const PageBackdropSettings shared = PageBackdropSettings(
        preset: PageBackdropPreset.custom,
        landscapeImagePath: 'l.png',
      );
      expect(shared.imagePathFor(portrait: true), 'l.png');
      final PageBackdropSettings split = shared.copyWith(
        portraitImagePath: () => 'p.png',
      );
      expect(split.imagePathFor(portrait: true), 'p.png');
      expect(split.imagePathFor(portrait: false), 'l.png');
    });

    test('遮罩浓度夹到合法区间，非数字回默认', () {
      expect(clampPageBackdropScrim(2), kPageBackdropScrimMax);
      expect(clampPageBackdropScrim(-1), kPageBackdropScrimMin);
      expect(clampPageBackdropScrim('x'), kPageBackdropScrimDefault);
    });

    test('偏好里的图片路径：空串、非字符串与判为不存在的都视为没有', () {
      final String path = writeImage();
      final String missing = '${scratch.path}/nope.png';
      bool exists(String p) => p != missing;
      expect(existingPageBackdropImagePath(path, exists: exists), path);
      expect(existingPageBackdropImagePath('', exists: exists), isNull);
      expect(existingPageBackdropImagePath(42, exists: exists), isNull);
      expect(existingPageBackdropImagePath(missing, exists: exists), isNull);
    });
  });

  group('LibraryShapeBackdrop 画不画', () {
    Future<void> pumpWith(
      WidgetTester tester,
      PageBackdropSettings settings, {
      bool glass = false,
      bool eink = false,
    }) async {
      pageBackdropSettings.value = settings;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: <ThemeExtension<dynamic>>[
              FushiGlassTheme(FushiGlassMaterial.off, glassDesign: glass),
              FushiEinkTheme(eink),
            ],
          ),
          home: const LibraryShapeBackdrop(child: SizedBox.expand()),
        ),
      );
    }

    Finder layer() => find.byType(PageBackdropLayer);

    testWidgets('Material 下形状预设画、纯色不画', (WidgetTester tester) async {
      await pumpWith(tester, const PageBackdropSettings());
      expect(layer(), findsOneWidget);

      pageBackdropSettings.value = const PageBackdropSettings(
        preset: PageBackdropPreset.plain,
      );
      await tester.pump();
      expect(layer(), findsNothing);

      pageBackdropSettings.value = const PageBackdropSettings(
        preset: PageBackdropPreset.wave,
      );
      await tester.pump();
      expect(layer(), findsOneWidget);
    });

    testWidgets('Apple 设计下形状不画，自定义图片照画', (WidgetTester tester) async {
      await pumpWith(
        tester,
        const PageBackdropSettings(preset: PageBackdropPreset.mesh),
        glass: true,
      );
      expect(layer(), findsNothing);

      pageBackdropSettings.value = PageBackdropSettings(
        preset: PageBackdropPreset.custom,
        landscapeImagePath: writeImage(),
      );
      await tester.pump();
      expect(layer(), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('墨水屏下连自定义图片也不画', (WidgetTester tester) async {
      await pumpWith(
        tester,
        PageBackdropSettings(
          preset: PageBackdropPreset.custom,
          landscapeImagePath: writeImage(),
        ),
        eink: true,
      );
      expect(layer(), findsNothing);
    });

    testWidgets('每种预设都能在任意尺寸下画出来不抛', (WidgetTester tester) async {
      final String image = writeImage();
      for (final PageBackdropPreset preset in PageBackdropPreset.values) {
        for (final Size size in const <Size>[
          Size(1280, 800),
          Size(390, 844),
          Size(112, 70),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: SizedBox.fromSize(
                  size: size,
                  child: PageBackdropLayer(
                    settings: PageBackdropSettings(
                      preset: preset,
                      landscapeImagePath: image,
                      motion: true,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull, reason: '$preset @ $size');
        }
      }
    });

    testWidgets('减弱动态效果时漂移不启动（没有持续帧）', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: PageBackdropLayer(
              settings: PageBackdropSettings(
                preset: PageBackdropPreset.sunny,
                motion: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('漂移开关来回切：重建动画不抛、开着时确实在动', (WidgetTester tester) async {
      Future<void> pumpMotion(bool motion) => tester.pumpWidget(
        MaterialApp(
          home: PageBackdropLayer(
            settings: PageBackdropSettings(
              preset: PageBackdropPreset.wave,
              motion: motion,
            ),
          ),
        ),
      );
      await pumpMotion(true);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await pumpMotion(false);
      expect(tester.binding.transientCallbackCount, 0);
      await pumpMotion(true);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });
  });
}
