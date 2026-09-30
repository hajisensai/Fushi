/// 桌面应用外悬浮球要的图片（契约见
/// `docs/specs/2026-09-30-desktop-system-floating-ball.md`）。
///
/// 原生窗口（Windows D2D / macOS AppKit）不加载 Flutter 的 Material Icons 字体：
/// 按钮图标由这里用与应用内球同一颗 [IconData] 画成已着色的 PNG 交过去，两边
/// 画出来就是同一个字形；球面是同一张 `assets/meta/icon.png`。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 图标 PNG 的边长：22 逻辑像素 × 3，原生按显示器缩放往下取样。
const int kDesktopSystemBallIconPx = 66;

/// 球面图（与应用内球同一张）。
const String kDesktopSystemBallImageAsset = 'assets/meta/icon.png';

/// 把 [icon] 按 [color] 画成 [size]×[size] 的透明底 PNG；画不出来返回 null。
Future<Uint8List?> renderFloatingBallIconPng(
  IconData icon,
  Color color, {
  int size = kDesktopSystemBallIconPx,
}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final TextPainter painter = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        inherit: false,
        fontSize: size.toDouble(),
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        fontFamilyFallback: icon.fontFamilyFallback,
        color: color,
        height: 1,
      ),
    ),
  )..layout();
  painter.paint(
    canvas,
    Offset((size - painter.width) / 2, (size - painter.height) / 2),
  );
  painter.dispose();
  final ui.Image image = await recorder.endRecording().toImage(size, size);
  try {
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// 按钮 id → 图标 PNG；某颗画失败就不带它（原生侧退化成只画底色圆）。
Future<Map<String, Uint8List>> renderFloatingBallIconPngs(
  Map<String, IconData> icons,
  Color color,
) async {
  final Map<String, Uint8List> out = <String, Uint8List>{};
  for (final MapEntry<String, IconData> e in icons.entries) {
    final Uint8List? png = await renderFloatingBallIconPng(e.value, color);
    if (png != null) out[e.key] = png;
  }
  return out;
}

/// 球面 PNG 原始字节；资源缺失返回 null（原生侧退化成纯色球）。
Future<Uint8List?> loadFloatingBallImage([AssetBundle? bundle]) async {
  try {
    final ByteData data = await (bundle ?? rootBundle).load(
      kDesktopSystemBallImageAsset,
    );
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    return null;
  }
}
