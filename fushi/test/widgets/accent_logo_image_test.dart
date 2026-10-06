import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';
import 'package:fushi/src/utils/components/accent_logo_image.dart';
import 'package:fushi/src/utils/components/current_app_icon.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
import 'package:fushi/src/utils/misc/logo_accent_tint.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:material_ui/material_ui.dart';

ColorScheme _preset(String key, Brightness brightness) =>
    ThemeNotifier.buildPresetColorScheme(
      ThemeNotifier.themePresets[key]!,
      brightness,
    );

Widget _host(ColorScheme scheme, Widget child) => MaterialApp(
  theme: ThemeData(colorScheme: scheme),
  home: Center(child: SizedBox.square(dimension: 64, child: child)),
);

/// 直接从磁盘读 asset 的 bundle（在 runAsync 里走真实 IO 解码）。
class _DiskBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final Uint8List bytes = await File(key).readAsBytes();
    return ByteData.sublistView(bytes);
  }
}

Future<ui.Image> _resolve(ImageProvider<Object> provider) {
  final Completer<ui.Image> done = Completer<ui.Image>();
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool sync) {
      stream.removeListener(listener);
      done.complete(info.image);
    },
    onError: (Object error, StackTrace? stack) {
      stream.removeListener(listener);
      done.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  return done.future;
}

void main() {
  setUp(() {
    currentAppIconSelection.value = const AppIconSelection(
      presetKey: 'default',
    );
    // 「图标跟随主题色」开关打开（默认关的行为见下面单独的组）。
    appLogoFollowsAccent.value = true;
  });

  tearDown(() => appLogoFollowsAccent.value = false);

  group('「图标跟随主题色」开关', () {
    testWidgets('默认关：任何主题下都是原图', (WidgetTester tester) async {
      appLogoFollowsAccent.value = false;
      await tester.pumpWidget(
        _host(_preset('m3-red', Brightness.dark), const CurrentAppIcon()),
      );
      final Image image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<AssetImage>());
      expect(
        (image.image as AssetImage).assetName,
        presetIconAssets['default'],
      );
    });

    testWidgets('运行中打开 → 立即着色；再关 → 回到原图', (WidgetTester tester) async {
      appLogoFollowsAccent.value = false;
      final ColorScheme teal = _preset('m3-teal', Brightness.light);
      await tester.pumpWidget(_host(teal, const CurrentAppIcon()));
      expect(tester.widget<Image>(find.byType(Image)).image, isA<AssetImage>());

      appLogoFollowsAccent.value = true;
      await tester.pump();
      final AccentLogoImage logo =
          tester.widget<Image>(find.byType(Image)).image as AccentLogoImage;
      expect(logo.tint, LogoAccentTint.fromAccent(teal.primary.toARGB32()));

      appLogoFollowsAccent.value = false;
      await tester.pump();
      expect(tester.widget<Image>(find.byType(Image)).image, isA<AssetImage>());
    });
  });

  group('rail 品牌位（CurrentAppIcon）吃 ColorScheme.primary', () {
    testWidgets('基线紫：仍是原 AssetImage（像素级等同改造前）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(_preset('m3-baseline', Brightness.light), const CurrentAppIcon()),
      );
      final Image image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<AssetImage>());
      expect(
        (image.image as AssetImage).assetName,
        presetIconAssets['default'],
      );
    });

    for (final Brightness brightness in Brightness.values) {
      testWidgets('青色主题（$brightness）：换成跟随 primary 的换色图', (
        WidgetTester tester,
      ) async {
        final ColorScheme scheme = _preset('m3-teal', brightness);
        await tester.pumpWidget(_host(scheme, const CurrentAppIcon()));
        final Image image = tester.widget<Image>(find.byType(Image));
        final AccentLogoImage logo = image.image as AccentLogoImage;
        expect(logo.assetName, presetIconAssets['default']);
        expect(logo.decodeWidth, appIconDecodePixelWidth);
        expect(logo.tint, LogoAccentTint.fromAccent(scheme.primary.toARGB32()));
        expect(image.gaplessPlayback, isTrue, reason: '换主题时不闪空');
      });
    }

    testWidgets('换主题即时重建：基线紫 → 红色 → 基线紫', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(_preset('m3-baseline', Brightness.light), const CurrentAppIcon()),
      );
      expect(tester.widget<Image>(find.byType(Image)).image, isA<AssetImage>());
      final ColorScheme red = _preset('m3-red', Brightness.light);
      await tester.pumpWidget(_host(red, const CurrentAppIcon()));
      // 主题交叉过渡期间不跟着每帧插值色换图（每张都要整图换色一次）。
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.widget<Image>(find.byType(Image)).image, isA<AssetImage>());
      // 过渡结束、强调色稳定后只提交最终那一张。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
      final AccentLogoImage logo =
          tester.widget<Image>(find.byType(Image)).image as AccentLogoImage;
      expect(logo.tint, LogoAccentTint.fromAccent(red.primary.toARGB32()));
      await tester.pumpWidget(
        _host(_preset('m3-baseline', Brightness.dark), const CurrentAppIcon()),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<Image>(find.byType(Image)).image, isA<AssetImage>());
    });

    testWidgets('用户自定义图标永远原样显示，不换色', (WidgetTester tester) async {
      currentAppIconSelection.value = const AppIconSelection(
        presetKey: customIconKey,
        customPath: 'C:/nowhere/custom.png',
      );
      await tester.pumpWidget(
        _host(_preset('m3-red', Brightness.light), const CurrentAppIcon()),
      );
      final Image image = tester.widget<Image>(find.byType(Image));
      expect((image.image as ResizeImage).imageProvider, isA<FileImage>());
    });
  });

  group('阅读器悬浮球吉祥物', () {
    test('基线紫：原图按 192 解码', () {
      final ImageProvider<Object> provider = readerFloatingBallMascotImage(
        LogoAccentTint.fromAccent(
          _preset('m3-baseline', Brightness.light).primary.toARGB32(),
        ),
      );
      final ResizeImage resized = provider as ResizeImage;
      expect(resized.width, kReaderFloatingBallMascotDecodeWidth);
      expect(
        (resized.imageProvider as AssetImage).assetName,
        kReaderFloatingBallIconAsset,
      );
    });

    test('其它强调色：换色图同样按 192 解码', () {
      final AccentLogoImage logo =
          readerFloatingBallMascotImage(
                LogoAccentTint.fromAccent(
                  _preset('m3-green', Brightness.dark).primary.toARGB32(),
                ),
              )
              as AccentLogoImage;
      expect(logo.assetName, kReaderFloatingBallIconAsset);
      expect(logo.decodeWidth, kReaderFloatingBallMascotDecodeWidth);
    });
  });

  testWidgets('AccentLogoImage 真解码：底色像素转到 primary 色相、alpha 不变', (
    WidgetTester tester,
  ) async {
    final ColorScheme scheme = _preset('m3-orange', Brightness.light);
    final LogoAccentTint tint = LogoAccentTint.fromAccent(
      scheme.primary.toARGB32(),
    );
    await tester.runAsync(() async {
      final _DiskBundle bundle = _DiskBundle();
      final ui.Codec codec = await ui.instantiateImageCodec(
        File(presetIconAssets['default']!).readAsBytesSync(),
        targetWidth: 64,
      );
      final ui.Image original = (await codec.getNextFrame()).image;
      codec.dispose();
      final ui.Image tinted = await _resolve(
        AccentLogoImage(
          presetIconAssets['default']!,
          tint: tint,
          decodeWidth: 64,
          bundle: bundle,
        ),
      );
      expect(tinted.width, 64);
      final ByteData a = (await original.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!;
      final ByteData b = (await tinted.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!;
      // 左上内侧（squircle 底色区）：(8, 8)。
      const int i = (8 * 64 + 8) * 4;
      int argb(ByteData d) =>
          (d.getUint8(i + 3) << 24) |
          (d.getUint8(i) << 16) |
          (d.getUint8(i + 1) << 8) |
          d.getUint8(i + 2);
      final Hct before = Hct.fromInt(argb(a));
      final Hct after = Hct.fromInt(argb(b));
      expect(after.tone, closeTo(before.tone, 1.5));
      final double expectedHue = (before.hue + tint.hueShift) % 360;
      final double d = (after.hue - expectedHue).abs() % 360;
      expect(d > 180 ? 360 - d : d, lessThan(5));
      // 透明角落仍透明。
      expect(b.getUint8(3), a.getUint8(3));
      original.dispose();
      tinted.dispose();
    });
  });
}
