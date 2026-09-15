/// 截图合成：把字幕层叠回截下来的那一帧上。
///
/// 为什么需要这一层：Hibiki 的字幕**不在画面里**——libmpv 侧 `sub-visibility=no`
/// （`video_mpv_config.dart` 的 `buildSubtitleSuppressionProperties`），字幕全部由
/// Flutter overlay 画在视频之上。于是 `Player.screenshot()` 拿到的永远是**裸画面**，
/// 想要「带字幕的截图」就得在 Dart 侧把字幕画回去。
///
/// 复用而非另起：字幕怎么画完全交给片段导出那套 [renderClipSubtitlePng]
/// （`video_clip_subtitle_image.dart`）——它按用户的 [VideoSubtitleStyle] 渲染成与
/// 画面同分辨率的全画幅透明 PNG。本文件只干最后一步「叠上去」，所以截图里的字幕与
/// 屏幕上、与导出的片段里逐像素同源，不会出现第三套外观。
///
/// 输出恒为 PNG：`ui.Image.toByteData` 只支持 png / rawRgba，而 PNG 对字幕这种
/// 高对比细线条也正好无损（JPEG 会在描边周围留振铃）。
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 把 [overlayPngs] 按给出顺序叠到 [frameBytes] 这一帧上，输出 PNG 字节。
///
/// [overlayPngs] 里每张都应当与画面同分辨率（[renderClipSubtitlePng] 的产物就是），
/// 尺寸不符时按原大小绘制在左上角，不缩放——与其猜用户想要哪种缩放，不如让不匹配
/// 肉眼可见。空列表是合法输入：此时等价于「把这一帧原样转成 PNG」，剪贴板路径要的
/// 就是这个（各端剪贴板都收 PNG，而截图原始字节是 JPEG）。
///
/// 解码/绘制失败返回 null（引擎拒绝、内存不足、字节不是图片）：调用方据此回退到
/// 不带字幕的原始字节，而不是让整次截图失败。
Future<Uint8List?> composeScreenshotWithOverlays({
  required Uint8List frameBytes,
  required List<Uint8List> overlayPngs,
}) async {
  ui.Image? base;
  final List<ui.Image> overlays = <ui.Image>[];
  try {
    base = await _decodeImage(frameBytes);
    if (base == null) return null;
    for (final Uint8List png in overlayPngs) {
      final ui.Image? layer = await _decodeImage(png);
      // 单层解不出来就跳过这一层——少一条字幕远好过整张截图没了。
      if (layer != null) overlays.add(layer);
    }

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    final ui.Paint paint = ui.Paint();
    canvas.drawImage(base, ui.Offset.zero, paint);
    for (final ui.Image layer in overlays) {
      canvas.drawImage(layer, ui.Offset.zero, paint);
    }
    final ui.Picture picture = recorder.endRecording();
    final ui.Image composed = await picture.toImage(base.width, base.height);
    try {
      final ByteData? png =
          await composed.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } finally {
      composed.dispose();
      picture.dispose();
    }
  } catch (_) {
    return null;
  } finally {
    base?.dispose();
    for (final ui.Image layer in overlays) {
      layer.dispose();
    }
  }
}

/// 帧的像素尺寸，解不出来返回 null。
///
/// 字幕排版要按**画面像素**算（[computeClipSubtitleLayout] 的 scale = 画面高 /
/// 屏幕上视频显示区高），所以合成前必须先知道这一帧多大。
Future<({int width, int height})?> screenshotFrameSize(
    Uint8List frameBytes) async {
  final ui.Image? image = await _decodeImage(frameBytes);
  if (image == null) return null;
  try {
    return (width: image.width, height: image.height);
  } finally {
    image.dispose();
  }
}

Future<ui.Image?> _decodeImage(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  try {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}
