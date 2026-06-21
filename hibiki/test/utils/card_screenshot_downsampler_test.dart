import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/card_screenshot_downsampler.dart';
import 'package:image/image.dart' as img;

/// TODO-646 守卫：制卡截图降采样。验证纯尺寸计算（只缩不放/等比/长边钉 1000）
/// 与端到端 decode→resize→encode（大图缩到长边 1000、小图原样不动、坏字节保守回退）。
void main() {
  group('computeDownsampledSize', () {
    test('landscape 4K downsamples long edge to 1000', () {
      final size = computeDownsampledSize(width: 3840, height: 2160);
      expect(size, isNotNull);
      expect(size!.width, 1000); // 长边钉 1000
      expect(size.height, 563); // 2160 * (1000/3840) = 562.5 → 563
    });

    test('portrait 1080x1920 pins the (long) height to 1000', () {
      final size = computeDownsampledSize(width: 1080, height: 1920);
      expect(size, isNotNull);
      expect(size!.height, 1000);
      expect(size.width, 563); // 1080 * (1000/1920) = 562.5 → 563
    });

    test('returns null when long edge already <= max (only shrink, never grow)',
        () {
      expect(computeDownsampledSize(width: 1000, height: 600), isNull);
      expect(computeDownsampledSize(width: 640, height: 480), isNull);
    });

    test('returns null for non-positive dimensions', () {
      expect(computeDownsampledSize(width: 0, height: 100), isNull);
      expect(computeDownsampledSize(width: 100, height: -1), isNull);
    });

    test('extreme aspect ratio clamps the short edge to at least 1', () {
      final size = computeDownsampledSize(width: 5000, height: 2);
      expect(size, isNotNull);
      expect(size!.width, 1000);
      expect(size.height, 1); // 2 * (1000/5000) = 0.4 → round 0 → clamp 1
    });

    test('honours a custom maxLongEdge', () {
      final size =
          computeDownsampledSize(width: 2000, height: 1000, maxLongEdge: 500);
      expect(size!.width, 500);
      expect(size.height, 250);
    });
  });

  group('downsampleCardScreenshot', () {
    Uint8List jpegOf(int width, int height) {
      final img.Image image = img.Image(width: width, height: height);
      img.fill(image, color: img.ColorRgb8(120, 60, 200));
      return img.encodeJpg(image, quality: 90);
    }

    test('shrinks a large screenshot so its long edge is 1000px', () {
      final Uint8List big = jpegOf(2400, 1350);
      final Uint8List out = downsampleCardScreenshot(big);
      final img.Image decoded = img.decodeImage(out)!;
      expect(decoded.width, 1000);
      expect(decoded.height, 563);
      // 降采样后体积更小（同质量、更少像素）。
      expect(out.lengthInBytes, lessThan(big.lengthInBytes));
    });

    test('leaves a small screenshot untouched (returns the same bytes)', () {
      final Uint8List small = jpegOf(800, 450);
      final Uint8List out = downsampleCardScreenshot(small);
      expect(identical(out, small), isTrue);
    });

    test('returns the input unchanged for empty bytes', () {
      final Uint8List empty = Uint8List(0);
      expect(identical(downsampleCardScreenshot(empty), empty), isTrue);
    });

    test('returns the input unchanged for undecodable bytes (no break)', () {
      final Uint8List garbage = Uint8List.fromList(<int>[0, 1, 2, 3, 4]);
      final Uint8List out = downsampleCardScreenshot(garbage);
      // 解码失败保守原样返回，绝不把有效封面替换成空字节。
      expect(identical(out, garbage), isTrue);
    });
  });
}
