/// 桌面应用外悬浮球要的图片（契约见
/// `docs/specs/2026-09-30-desktop-system-floating-ball.md`）。
///
/// 原生窗口（Windows D2D / macOS AppKit）不加载 Flutter 的图标字体：按钮图标由
/// 这里用与应用内球同一颗 [IconData]（FushiIcons 语义图标）画成已着色的 PNG 交
/// 过去，两边画出来就是同一个字形；球面是同一只吉祥物叠在当前主题的
/// primaryContainer 上（[renderFloatingBallFacePng]），原生只按圆裁切。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';
import 'package:fushi/src/utils/components/accent_logo_image.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/logo_accent_tint.dart';

/// 图标 PNG 的边长：22 逻辑像素 × 3，原生按显示器缩放往下取样。
const int kDesktopSystemBallIconPx = 66;

/// 球面吉祥物图（与应用内球同一张透明底前景）。
const String kDesktopSystemBallImageAsset = kReaderFloatingBallIconAsset;

/// 球面 PNG 的边长：48 逻辑像素 × 4，原生按显示器缩放往下取样。
const int kDesktopSystemBallFacePx = 192;

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
  final ui.Picture picture = recorder.endRecording();
  try {
    final ui.Image image = await picture.toImage(size, size);
    try {
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

/// 画单颗图标的函数形状（[renderFloatingBallIconPng] 的签名）。
typedef FloatingBallIconRenderer =
    Future<Uint8List?> Function(IconData icon, Color color);

/// 按钮 id → 图标 PNG；某颗画失败就不带它（原生侧退化成只画底色圆）。
/// [render] 只给测试替换单颗的画法，用来钉住逐颗容错。
Future<Map<String, Uint8List>> renderFloatingBallIconPngs(
  Map<String, IconData> icons,
  Color color, {
  @visibleForTesting FloatingBallIconRenderer? render,
}) async {
  final FloatingBallIconRenderer draw =
      render ??
      (IconData icon, Color color) => renderFloatingBallIconPng(icon, color);
  final Map<String, Uint8List> out = <String, Uint8List>{};
  for (final MapEntry<String, IconData> e in icons.entries) {
    try {
      final Uint8List? png = await draw(e.value, color);
      if (png != null) out[e.key] = png;
    } catch (error, stack) {
      // 一颗画不出来不拖累其余按钮与起球；记下来，别静默。
      ErrorLogService.instance.log(
        'floating_ball.icon_png.${e.key}',
        error,
        stack,
      );
    }
  }
  return out;
}

/// 球面 PNG：[container]（当前主题的 primaryContainer，墨水屏是 surface）铺满
/// 正方形、吉祥物按应用内同一倍数（[kReaderFloatingBallMascotScale]）居中。原生
/// 侧取中心正方形按圆裁切，所以画出来与应用内收起态的球面同色同形。吉祥物资源
/// 缺失 / 解码失败时只画底色（记日志）；整张画不出来返回 null（原生退化成纯色球）。
///
/// [accent]（当前主题 primary，墨水屏是 surface）给了就让吉祥物跟随强调色，与应用
/// 内球同一套换色（[readerFloatingBallMascotImage]）。
Future<Uint8List?> renderFloatingBallFacePng(
  Color container, {
  Color? accent,
  AssetBundle? bundle,
  int size = kDesktopSystemBallFacePx,
}) async {
  final Uint8List? mascot = await loadFloatingBallImage(bundle);
  ui.Image? mascotImage;
  if (mascot != null) {
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(mascot);
      try {
        mascotImage = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      final LogoAccentTint tint = accent == null
          ? LogoAccentTint.identity
          : LogoAccentTint.fromAccent(accent.toARGB32());
      if (!tint.isIdentity) {
        final ui.Image original = mascotImage;
        try {
          mascotImage = await tintLogoImage(original, tint);
          original.dispose();
        } catch (error, stack) {
          // 换色失败退回原配色吉祥物，球面照样有图。
          ErrorLogService.instance.log(
            'floating_ball.ball_face_tint',
            error,
            stack,
          );
        }
      }
    } catch (error, stack) {
      ErrorLogService.instance.log('floating_ball.ball_face', error, stack);
    }
  }
  final double side = size.toDouble();
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, side, side), Paint()..color = container);
  final ui.Image? image = mascotImage;
  if (image != null) {
    final double extent = side * kReaderFloatingBallMascotScale;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: Offset(side / 2, side / 2),
        width: extent,
        height: extent,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
    image.dispose();
  }
  final ui.Picture picture = recorder.endRecording();
  try {
    final ui.Image face = await picture.toImage(size, size);
    try {
      final ByteData? data = await face.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return data?.buffer.asUint8List();
    } finally {
      face.dispose();
    }
  } catch (error, stack) {
    ErrorLogService.instance.log('floating_ball.ball_face', error, stack);
    return null;
  } finally {
    picture.dispose();
  }
}

/// 球面吉祥物 PNG 原始字节；资源缺失返回 null（[renderFloatingBallFacePng] 只画
/// 底色）。
Future<Uint8List?> loadFloatingBallImage([AssetBundle? bundle]) async {
  try {
    final ByteData data = await (bundle ?? rootBundle).load(
      kDesktopSystemBallImageAsset,
    );
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on FlutterError catch (error, stack) {
    // AssetBundle.load 找不到资源抛 FlutterError（「Unable to load asset」）。
    ErrorLogService.instance.log('floating_ball.ball_image', error, stack);
    return null;
  }
}
