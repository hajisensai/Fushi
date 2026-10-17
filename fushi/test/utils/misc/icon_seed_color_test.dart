import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/icon_seed_color.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// 生成 [size]² 的非预乘 RGBA：中心 [inner]² 方块是 [fg]，其余是 [bg]（含 alpha）。
Uint8List _icon({
  required int fg,
  required int bg,
  int size = 32,
  int inner = 16,
}) {
  final Uint8List out = Uint8List(size * size * 4);
  final int lo = (size - inner) ~/ 2;
  final int hi = lo + inner;
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final int c = x >= lo && x < hi && y >= lo && y < hi ? fg : bg;
      final int i = (y * size + x) * 4;
      out[i] = (c >> 16) & 0xFF;
      out[i + 1] = (c >> 8) & 0xFF;
      out[i + 2] = c & 0xFF;
      out[i + 3] = (c >> 24) & 0xFF;
    }
  }
  return out;
}

double _hueDistance(double a, double b) {
  final double d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

void main() {
  test('彩色图标：种子取图标主色', () async {
    final int? seed = await iconSeedFromRgba(
      _icon(fg: 0xFF2E7D32, bg: 0xFFFFFFFF, inner: 24),
    );
    expect(seed, isNotNull);
    expect(
      _hueDistance(Hct.fromInt(seed!).hue, Hct.fromInt(0xFF2E7D32).hue),
      lessThan(10),
    );
  });

  test('透明像素不参与：透明区藏着的蓝色不会把种子拉偏', () async {
    // 透明底的 RGB 是任意值（这里故意填满鲜蓝），只有中间的红是真实图标。
    final int? seed = await iconSeedFromRgba(
      _icon(fg: 0xFFC62828, bg: 0x001565C0, inner: 10),
    );
    expect(seed, isNotNull);
    expect(
      _hueDistance(Hct.fromInt(seed!).hue, Hct.fromInt(0xFFC62828).hue),
      lessThan(10),
    );
  });

  test('灰阶图标：得到无彩度种子，而不是 Score 的谷歌蓝兜底', () async {
    final int? seed = await iconSeedFromRgba(
      _icon(fg: 0xFF404040, bg: 0xFFE0E0E0),
    );
    expect(seed, isNotNull);
    expect(seed, isNot(0xFF4285F4));
    expect(Hct.fromInt(seed!).chroma, lessThan(5));
  });

  test('全透明图片：没有可用像素返回 null', () async {
    expect(
      await iconSeedFromRgba(_icon(fg: 0x00FF0000, bg: 0x00000000)),
      isNull,
    );
  });
}
