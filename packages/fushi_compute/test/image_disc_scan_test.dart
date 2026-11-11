import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// 24 位 BMP（宽为 4 的倍数，免行补齐）。[pixel] 给 (x, y) 的 RGB。
Uint8List _bmp(int w, int h, List<int> Function(int x, int y) pixel) {
  assert(w % 4 == 0);
  final int size = 54 + w * h * 3;
  final ByteData b = ByteData(size)
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, size, Endian.little)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, w, Endian.little)
    ..setInt32(22, h, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 24, Endian.little);
  int o = 54;
  for (int y = h - 1; y >= 0; y--) {
    for (int x = 0; x < w; x++) {
      final List<int> c = pixel(x, y);
      b
        ..setUint8(o++, c[2])
        ..setUint8(o++, c[1])
        ..setUint8(o++, c[0]);
    }
  }
  return b.buffer.asUint8List();
}

/// 按真实 CD 比例合成的盘面扫描：白底、孔（半径 0.125）透底、浅灰夹持环、蓝色印刷面、
/// 外缘深色描边。
Uint8List _disc(int n) {
  final double c = (n - 1) / 2;
  final double r = n / 2;
  return _bmp(n, n, (int x, int y) {
    final double d = math.sqrt(math.pow(x - c, 2) + math.pow(y - c, 2)) / r;
    if (d < 0.125) return <int>[255, 255, 255];
    if (d < 0.32) return <int>[170, 175, 180];
    if (d < 0.96) return <int>[40, 90, 200];
    if (d < 1.0) return <int>[60, 60, 60];
    return <int>[255, 255, 255];
  });
}

void main() {
  final FushiComputeImage image = FushiComputeImage.instance;

  test('盘面扫描判为盘', () {
    final FfcDiscScan? scan = image.discScan(_disc(256));
    expect(scan, isNotNull);
    expect(scan!.isDisc, isTrue, reason: '$scan');
    expect(scan.edgeCoverage, greaterThan(0.8));
  });

  test('空白页、满幅插画不是盘', () {
    expect(
      image.discScan(_bmp(256, 256, (_, _) => <int>[250, 250, 250]))!.isDisc,
      isFalse,
    );
    expect(
      image
          .discScan(
            _bmp(256, 256, (int x, int y) => <int>[x, y, (x + y) ~/ 2]),
          )!
          .isDisc,
      isFalse,
    );
  });

  test('不近正方只读头判否，特征为 NaN', () {
    final FfcDiscScan scan = image.discScan(
      _bmp(512, 256, (_, _) => <int>[255, 255, 255]),
    )!;
    expect(scan.isDisc, isFalse);
    expect(scan.aspect, 2);
    expect(scan.backgroundStd.isNaN, isTrue);
  });

  test('解不开返回 null', () {
    expect(image.discScan(Uint8List.fromList(<int>[1, 2, 3, 4])), isNull);
  });
}
