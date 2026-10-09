/// 「主题色跟随图标」：从用户自定义的应用图标里取主题种子色。
///
/// 与 Flutter `ColorScheme.fromImageProvider`（壁纸 / 封面动态取色）同一套
/// material_color_utilities 流程：Celebi 量化 → [Score] 挑最适合当种子的颜色。
/// 区别只在两点：按小尺寸解码后整段放进后台 isolate；透明像素不参与（自定义
/// 图标常是透明底，透明区的 RGB 是任意值，算进去会把种子拉偏）。
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// 取色解码边长：与 `ColorScheme.fromImageProvider` 的 112 同量级，够量化用。
const int kIconSeedDecodeWidth = 112;

/// Celebi 量化的最大簇数（与 `ColorScheme.fromImageProvider` 一致）。
const int kIconSeedQuantizeColors = 128;

/// 低于这个 alpha 的像素不参与取色。
const int kIconSeedMinAlpha = 128;

/// 非预乘 RGBA8888 像素 → 种子色 ARGB；没有可用像素返回 null。
///
/// 有彩色时按 [Score] 的默认筛选挑；整张图都是灰阶（筛选后一个不剩）时不用
/// [Score] 的谷歌蓝兜底，而是关掉筛选取占比最高的灰——灰图标就该得到灰主题
/// （`buildFushiColorScheme` 对无彩度种子走 monochrome）。
Future<int?> iconSeedFromRgba(Uint8List rgba) async {
  final List<int> pixels = <int>[];
  for (int i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < kIconSeedMinAlpha) continue;
    pixels.add(0xFF000000 | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]);
  }
  if (pixels.isEmpty) return null;
  final QuantizerResult quantized = await QuantizerCelebi().quantize(
    pixels,
    kIconSeedQuantizeColors,
  );
  const int noneSentinel = 0x00000000;
  final List<int> scored = Score.score(
    quantized.colorToCount,
    desired: 1,
    fallbackColorARGB: noneSentinel,
  );
  if (scored.isNotEmpty && scored.first != noneSentinel) return scored.first;
  final List<int> unfiltered = Score.score(
    quantized.colorToCount,
    desired: 1,
    fallbackColorARGB: noneSentinel,
    filter: false,
  );
  if (unfiltered.isNotEmpty && unfiltered.first != noneSentinel) {
    return unfiltered.first;
  }
  // 极端情况（全被量化成同一簇且分数全被筛掉）：取占比最高的那个簇。
  int? best;
  int bestCount = -1;
  quantized.colorToCount.forEach((int argb, int count) {
    if (count > bestCount) {
      best = argb;
      bestCount = count;
    }
  });
  return best;
}

/// 解码图片字节（按 [kIconSeedDecodeWidth] 缩小）并在后台 isolate 取种子色；
/// 解不出来返回 null。
Future<int?> extractIconSeedArgb(Uint8List encoded) async {
  final ui.Codec codec = await ui.instantiateImageCodec(
    encoded,
    targetWidth: kIconSeedDecodeWidth,
  );
  final ui.Image image;
  try {
    image = (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
  try {
    final ByteData? raw = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (raw == null) return null;
    return await compute(
      iconSeedFromRgba,
      raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes),
    );
  } finally {
    image.dispose();
  }
}
