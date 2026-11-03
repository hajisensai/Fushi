/// 「主题色跟随图标」：从用户自定义的应用图标里取主题种子色。
///
/// 与 Flutter `ColorScheme.fromImageProvider`（壁纸 / 封面动态取色）同一套
/// material_color_utilities 流程：Celebi 量化 → [Score] 挑最适合当种子的颜色。
/// 区别只在两点：按小尺寸解码后整段放进后台 isolate；透明像素不参与（自定义
/// 图标常是透明底，透明区的 RGB 是任意值，算进去会把种子拉偏）。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
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

/// 一张图的多个候选种子色（ARGB，按适合程度排序，最多 [desired] 个）：给「页面
/// 背景图取色」让用户挑。与 [iconSeedFromRgba] 同一套量化 + [Score]（Score 自带
/// 色相间距筛选，候选之间不会是同一种颜色的深浅）；整张图都是灰阶时退回占比最高
/// 的那一个灰。没有可用像素返回空表。
Future<List<int>> seedCandidatesFromRgba(Uint8List rgba, int desired) async {
  final List<int> pixels = <int>[];
  for (int i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < kIconSeedMinAlpha) continue;
    pixels.add(0xFF000000 | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]);
  }
  if (pixels.isEmpty) return const <int>[];
  final QuantizerResult quantized = await QuantizerCelebi().quantize(
    pixels,
    kIconSeedQuantizeColors,
  );
  const int noneSentinel = 0x00000000;
  final List<int> scored = Score.score(
    quantized.colorToCount,
    desired: desired,
    fallbackColorARGB: noneSentinel,
  ).where((int argb) => argb != noneSentinel).toList();
  if (scored.isNotEmpty) return scored;
  final int? gray = await iconSeedFromRgba(rgba);
  return gray == null ? const <int>[] : <int>[gray];
}

/// 解码图片字节（按 [kIconSeedDecodeWidth] 缩小）并在后台 isolate 取最多
/// [desired] 个候选种子色；解不出来返回空表。
Future<List<int>> extractImageSeedCandidates(
  Uint8List encoded, {
  required int desired,
}) async {
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
    if (raw == null) return const <int>[];
    final Uint8List rgba = raw.buffer.asUint8List(
      raw.offsetInBytes,
      raw.lengthInBytes,
    );
    return await compute(
      (Uint8List bytes) => seedCandidatesFromRgba(bytes, desired),
      rgba,
    );
  } finally {
    image.dispose();
  }
}

/// 把任意 [ImageProvider]（封面 / 剧照）解析成图后，缩到长边不超过
/// [kIconSeedDecodeWidth] 取非预乘 RGBA，在后台 isolate 跑 [iconSeedFromRgba]。
///
/// 取代 `ColorScheme.fromImageProvider` 做封面取色：那条路在 UI isolate 上同步跑
/// Celebi 量化，且透明 / 全灰阶图会落到 [Score] 的谷歌蓝兜底（无封面占位是透明
/// 1×1 图，整张卡会被染成蓝色）。这里透明像素不参与、灰阶图得到灰种子，没有可用
/// 像素返回 null（调用方退回中性色）。图片加载失败抛出错误。
Future<int?> extractImageProviderSeedArgb(
  ImageProvider provider, {
  Duration loadTimeout = const Duration(seconds: 10),
}) async {
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  final Completer<ImageInfo> loaded = Completer<ImageInfo>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool _) {
      stream.removeListener(listener);
      if (!loaded.isCompleted) loaded.complete(info);
    },
    onError: (Object error, StackTrace? stack) {
      stream.removeListener(listener);
      if (!loaded.isCompleted) loaded.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  final ImageInfo info;
  try {
    info = await loaded.future.timeout(loadTimeout);
  } on TimeoutException {
    stream.removeListener(listener);
    rethrow;
  }
  final ui.Image scaled;
  try {
    final ui.Image source = info.image;
    final int longest = source.width > source.height
        ? source.width
        : source.height;
    if (longest <= 0) return null;
    final double scale = longest > kIconSeedDecodeWidth
        ? kIconSeedDecodeWidth / longest
        : 1;
    final int w = (source.width * scale).round().clamp(1, kIconSeedDecodeWidth);
    final int h = (source.height * scale).round().clamp(
      1,
      kIconSeedDecodeWidth,
    );
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    paintImage(
      canvas: ui.Canvas(recorder),
      rect: ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      image: source,
      filterQuality: ui.FilterQuality.low,
    );
    final ui.Picture picture = recorder.endRecording();
    try {
      scaled = await picture.toImage(w, h);
    } finally {
      picture.dispose();
    }
  } finally {
    info.dispose();
  }
  try {
    final ByteData? raw = await scaled.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (raw == null) return null;
    return await compute(
      iconSeedFromRgba,
      raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes),
    );
  } finally {
    scaled.dispose();
  }
}
