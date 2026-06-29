import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/startup/observe_blank_detector.dart';

Uint8List _solid(int w, int h, int r, int g, int b) {
  final Uint8List buf = Uint8List(w * h * 4);
  for (int p = 0; p < w * h; p++) {
    buf[p * 4] = r;
    buf[p * 4 + 1] = g;
    buf[p * 4 + 2] = b;
    buf[p * 4 + 3] = 255;
  }
  return buf;
}

void main() {
  test('纯白帧判为空白', () {
    expect(rgbaLooksNonBlank(_solid(64, 64, 255, 255, 255)), isFalse);
  });

  test('纯色（非白）帧也判为空白', () {
    expect(rgbaLooksNonBlank(_solid(64, 64, 10, 20, 30)), isFalse);
  });

  test('多色帧判为非空白', () {
    final Uint8List buf = _solid(64, 64, 0, 0, 0);
    for (int k = 0; k < 20; k++) {
      final int i = k * 4;
      buf[i] = (k * 13) & 0xff;
      buf[i + 1] = (k * 29) & 0xff;
      buf[i + 2] = (k * 47) & 0xff;
    }
    expect(rgbaLooksNonBlank(buf), isTrue);
  });

  test('空缓冲安全返回 false', () {
    expect(rgbaLooksNonBlank(Uint8List(0)), isFalse);
  });

  test('量化后恰好 threshold-1 色判为空白', () {
    final Uint8List buf = _solid(64, 64, 0, 0, 0); // 基色 (0,0,0)
    // 造 10 个不同量化色（r=8..80 → >>3 得 1..10）+ 基色 0 = 共 11 色。
    for (int k = 1; k <= 10; k++) {
      buf[k * 4] = k * 8; // r 通道，>>3 后得 k，互不相同
    }
    expect(rgbaLooksNonBlank(buf), isFalse); // 共 11 量化色 < 12
  });

  test('量化后达到 threshold 色判为非空白', () {
    final Uint8List buf = _solid(64, 64, 0, 0, 0); // 基色 0
    for (int k = 1; k <= 11; k++) {
      buf[k * 4] = k * 8; // r=8..88 → >>3 得 1..11
    }
    // 基色 0 + 1..11 = 共 12 量化色 == threshold(12)
    expect(rgbaLooksNonBlank(buf), isTrue);
  });

  test('大图中成片多色区域判为非空白', () {
    const int w = 200, h = 200; // 40000 像素 > 4096 → stride>1
    final Uint8List buf = _solid(w, h, 255, 255, 255); // 整张白底
    // 左上角 60x60 涂成渐变多色块（成片，采样必命中）
    for (int y = 0; y < 60; y++) {
      for (int x = 0; x < 60; x++) {
        final int i = (y * w + x) * 4;
        buf[i] = (x * 4) & 0xff;
        buf[i + 1] = (y * 4) & 0xff;
        buf[i + 2] = ((x + y) * 2) & 0xff;
      }
    }
    expect(rgbaLooksNonBlank(buf), isTrue);
  });
}
