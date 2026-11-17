@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

// 无损 8×2 RGBA：第一行黑色、第二行 RGB(30,90,150)。
Uint8List _basePng() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAgAAAACCAYAAABllJ3tAAAAFUlEQVR4nGNgYGD4'
  'jxfLRU37jw8DAIIYGGFwkYVmAAAAAElFTkSuQmCC',
);

void main() {
  test('full-page overlay hides old pixels and keeps transparent areas', () {
    final FushiComputeImage kernel = FushiComputeImage.instance;
    final Uint8List base = _basePng();
    final Uint8List overlay = Uint8List(8 * 2 * 4);
    // 第一行整块白底，第二行保持透明。
    overlay.fillRange(0, 8 * 4, 255);
    final Uint8List? jpeg = kernel.compositeRgbaJpeg(
      base,
      overlay,
      width: 8,
      height: 2,
      quality: 100,
    );
    expect(jpeg, isNotNull);
    final FfcDecodedImage decoded = kernel.decode(jpeg!)!;
    expect((decoded.width, decoded.height, decoded.channels), (8, 2, 3));
    expect(decoded.pixels.take(8 * 3), everyElement(greaterThanOrEqualTo(253)));
    for (int channel = 0; channel < 3; channel++) {
      expect(
        decoded.pixels[8 * 3 + channel],
        closeTo(<int>[30, 90, 150][channel], 3),
      );
    }
    // 两个输入缓冲均为只读；FFI 不能覆盖源字节，也不能让覆盖层暂存区覆掉源图。
    expect(base, orderedEquals(_basePng()));
    expect(overlay.take(8 * 4), everyElement(255));
    expect(overlay.skip(8 * 4), everyElement(0));
  });

  test('invalid inputs fail closed instead of returning the source bytes', () {
    final FushiComputeImage kernel = FushiComputeImage.instance;
    for (final ({int width, int height, int quality, int length}) spec
        in <({int width, int height, int quality, int length})>[
          (width: 8, height: 2, quality: 85, length: 63),
          (width: 0, height: 2, quality: 85, length: 0),
          (width: 1281, height: 1, quality: 85, length: 1281 * 4),
          (width: 8, height: 2, quality: 0, length: 64),
          (width: 9, height: 2, quality: 85, length: 9 * 2 * 4),
        ]) {
      expect(
        kernel.compositeRgbaJpeg(
          _basePng(),
          Uint8List(spec.length),
          width: spec.width,
          height: spec.height,
          quality: spec.quality,
        ),
        isNull,
      );
    }
    expect(
      kernel.compositeRgbaJpeg(
        Uint8List.fromList(<int>[1, 2, 3]),
        Uint8List(4),
        width: 1,
        height: 1,
        quality: 85,
      ),
      isNull,
    );
  });
}
