import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:transparent_image/transparent_image.dart';

import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart';
import 'package:fushi/src/utils/misc/icon_seed_color.dart';

ImageProvider _img(String name) => AssetImage('cover/$name.png');

const int _red = 0xFFE53935;
const int _green = 0xFF43A047;
const int _blue = 0xFF1E88E5;

/// [size]² 的纯色 PNG（[argb] 含 alpha），编码成 [MemoryImage]。
Future<MemoryImage> _solidPng(int argb, {int size = 24}) async {
  final Uint8List rgba = Uint8List(size * size * 4);
  for (int i = 0; i < rgba.length; i += 4) {
    rgba[i] = (argb >> 16) & 0xFF;
    rgba[i + 1] = (argb >> 8) & 0xFF;
    rgba[i + 2] = argb & 0xFF;
    rgba[i + 3] = (argb >> 24) & 0xFF;
  }
  final Completer<ui.Image> done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    size,
    size,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  final ui.Image image = await done.future;
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return MemoryImage(png!.buffer.asUint8List());
}

double _chroma(int argb) {
  final int r = (argb >> 16) & 0xFF;
  final int g = (argb >> 8) & 0xFF;
  final int b = argb & 0xFF;
  final int hi = <int>[r, g, b].reduce((int a, int c) => a > c ? a : c);
  final int lo = <int>[r, g, b].reduce((int a, int c) => a < c ? a : c);
  return (hi - lo).toDouble();
}

void main() {
  group('CoverColorSchemeCache', () {
    test('evicts least recently used entries beyond capacity', () {
      final CoverColorSchemeCache cache = CoverColorSchemeCache(capacity: 2);
      cache.debugStoreSeed(_img('a'), _red);
      cache.debugStoreSeed(_img('b'), _green);
      // 命中 a：a 变成最近使用，b 成为最旧。
      expect(cache.peek(_img('a'), Brightness.light), isNotNull);
      cache.debugStoreSeed(_img('c'), _blue);

      expect(cache.length, 2);
      expect(cache.peek(_img('b'), Brightness.light), isNull);
      expect(cache.peek(_img('a'), Brightness.light), isNotNull);
      expect(cache.peek(_img('c'), Brightness.light), isNotNull);
    });

    test('one seed serves both brightnesses via buildFushiColorScheme', () {
      final CoverColorSchemeCache cache = CoverColorSchemeCache(capacity: 4);
      cache.debugStoreSeed(_img('a'), _red);
      expect(
        cache.peek(_img('a'), Brightness.light),
        buildFushiColorScheme(
          seedColor: const Color(_red),
          brightness: Brightness.light,
        ),
      );
      expect(
        cache.peek(_img('a'), Brightness.dark),
        buildFushiColorScheme(
          seedColor: const Color(_red),
          brightness: Brightness.dark,
        ),
      );
      expect(cache.length, 1);
    });

    test(
      'resolve extracts once per provider and dedups in-flight calls',
      () async {
        int calls = 0;
        final Completer<int?> gate = Completer<int?>();
        final CoverColorSchemeCache cache = CoverColorSchemeCache(
          extractSeed: (ImageProvider _) {
            calls++;
            return gate.future;
          },
        );
        final Future<ColorScheme?> a = cache.resolve(
          _img('a'),
          Brightness.light,
        );
        final Future<ColorScheme?> b = cache.resolve(
          _img('a'),
          Brightness.dark,
        );
        gate.complete(_red);
        expect(await a, isNotNull);
        expect((await b)!.brightness, Brightness.dark);
        expect(await cache.resolve(_img('a'), Brightness.light), isNotNull);
        expect(calls, 1);
      },
    );

    test('no usable pixels or failures cache null (neutral card)', () async {
      int calls = 0;
      final CoverColorSchemeCache cache = CoverColorSchemeCache(
        extractSeed: (ImageProvider image) async {
          calls++;
          if (image == _img('broken')) throw StateError('decode failed');
          return null;
        },
      );
      expect(await cache.resolve(_img('empty'), Brightness.light), isNull);
      expect(await cache.resolve(_img('broken'), Brightness.light), isNull);
      expect(await cache.resolve(_img('broken'), Brightness.light), isNull);
      expect(calls, 2, reason: '失败也记 null，不反复重算');
      expect(cache.length, 2);
    });
  });

  group('extractImageProviderSeedArgb', () {
    testWidgets(
      'transparent placeholder has no seed (no Google-blue fallback)',
      (WidgetTester tester) async {
        final int? seed = await tester.runAsync<int?>(
          () => extractImageProviderSeedArgb(MemoryImage(kTransparentImage)),
        );
        expect(seed, isNull);
      },
    );

    testWidgets('grayscale cover yields a gray seed, not Google blue', (
      WidgetTester tester,
    ) async {
      final int? seed = await tester.runAsync<int?>(() async {
        final MemoryImage gray = await _solidPng(0xFF7A7A7A);
        return extractImageProviderSeedArgb(gray);
      });
      expect(seed, isNotNull);
      expect(seed, isNot(0xFF4285F4));
      expect(_chroma(seed!), lessThan(8));
    });

    testWidgets('colored cover yields its own hue', (
      WidgetTester tester,
    ) async {
      final int? seed = await tester.runAsync<int?>(() async {
        final MemoryImage red = await _solidPng(_red, size: 300);
        return extractImageProviderSeedArgb(red);
      });
      expect(seed, isNotNull);
      final int r = (seed! >> 16) & 0xFF;
      final int b = seed & 0xFF;
      expect(r, greaterThan(b + 80));
    });
  });
}
