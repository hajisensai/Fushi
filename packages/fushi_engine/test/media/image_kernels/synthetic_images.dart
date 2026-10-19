// 图像内核回归向量用的确定性合成图：梯度 + 硬边块 + 线稿 + 伪随机噪点（固定种子 LCG），
// 覆盖缩放 / 均值 / 截断最容易出差的平滑区、跳变边与网点。
//
// 回归向量（image_kernel_vectors.dart）是 2026-10-18 用当时的纯 Dart 实现
// （package:image 4.3.0 的 copyResize / getPixel 循环）在这些图上生成的摘要；
// 这里的生成规则改了，向量就全部失效，不要动。
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 32 位 LCG（Numerical Recipes 常数），跨平台确定。
class SynthRng {
  SynthRng(int seed) : _state = seed & 0xffffffff;

  int _state;

  int next() {
    _state = (_state * 1664525 + 1013904223) & 0xffffffff;
    return _state >>> 8;
  }

  int below(int n) => next() % n;
}

/// [width] × [height]、[channels] 通道的 uint8 合成图。
img.Image synthImage(int width, int height, int channels, int seed) {
  final SynthRng rng = SynthRng(seed);
  final Uint8List px = Uint8List(width * height * channels);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int i = (y * width + x) * channels;
      for (int c = 0; c < channels; c++) {
        // 斜向梯度，各通道相位不同。
        int v =
            ((x * (3 + c) + y * (5 - c)) * 255 ~/ (width + height + 1)) & 0xff;
        // 硬边块：每 37 像素一格的棋盘。
        if (((x ~/ 37) + (y ~/ 37)) % 3 == 0) v = 255 - v;
        // 竖向细线稿（模拟漫画线条）。
        if ((x + seed) % 23 == 0 || (y * 7 + x) % 61 == 0) v = 12;
        // 噪点（网点 / JPEG 噪声）。
        v = (v + rng.below(31) - 15).clamp(0, 255);
        px[i + c] = v;
      }
      if (channels == 4) {
        // alpha：大部分不透明，留几片半透明与全透明。
        final int a = (x ~/ 19 + y ~/ 13) % 7;
        px[i + 3] = a == 0 ? 0 : (a == 1 ? 128 : (a == 2 ? 200 : 255));
      }
    }
  }
  return img.Image.fromBytes(
    width: width,
    height: height,
    bytes: px.buffer,
    numChannels: channels,
  );
}

/// 仿 DB 概率图：若干条带状「文字行」（横 / 竖、带缺口与倾斜）叠在弱噪声上。
Float32List synthProbMap(int width, int height, int seed) {
  final SynthRng rng = SynthRng(seed);
  final Float32List p = Float32List(width * height);
  for (int i = 0; i < p.length; i++) {
    p[i] = rng.below(1000) / 1000 * 0.25; // 背景，偶尔越过 0.2
  }
  final int lines = 6 + rng.below(10);
  for (int l = 0; l < lines; l++) {
    final bool vertical = rng.below(2) == 0;
    final int thick = 3 + rng.below(9);
    final int len = 20 + rng.below(vertical ? height : width);
    final int x0 = rng.below(width);
    final int y0 = rng.below(height);
    final int slope = rng.below(5) - 2; // 每 16 像素偏 slope
    for (int t = 0; t < len; t++) {
      if (rng.below(17) == 0) continue; // 缺口
      for (int k = 0; k < thick; k++) {
        final int x = vertical ? x0 + k + (t * slope) ~/ 16 : x0 + t;
        final int y = vertical ? y0 + t : y0 + k + (t * slope) ~/ 16;
        if (x < 0 || y < 0 || x >= width || y >= height) continue;
        p[y * width + x] = 0.3 + rng.below(700) / 1000;
      }
    }
  }
  return p;
}
