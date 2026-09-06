/// 片段导出的字幕**渲染**：把一条 cue 画成与视频同分辨率的全画幅透明 PNG，
/// 交给 `video_clip_subtitle_burn.dart` 的 `overlay` 链烧进画面（BUG-2202）。
///
/// 为什么整帧而不是「只画字那一小块 + 让 ffmpeg 定位」：定位、换行、描边、注音全在
/// Dart 侧算完，filter 图里就零布局逻辑，`ffmpeg-min` 的 filter 白名单只需要 overlay
/// 一个词。而且字号/描边/投影直接复用屏幕上那套 [VideoSubtitleStyle]，导出的字幕与
/// 用户看到的是同一套渲染，不是 libass 的另一套默认样式。
///
/// 尺寸怎么对齐：屏幕上的字号是**逻辑像素**、量在视频显示区上；导出要落到视频的
/// **像素**分辨率上。两者的比例就是 [ClipSubtitleLayout.scale] = 画面高 / 显示区高，
/// 于是「字幕占画面的比例」在屏幕和导出件里完全一致——这正是「所见即所得」的定义。
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:fushi/src/media/video/video_clip_subtitle_burn.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';

/// 视频显示区高度取不到时的回退基准（逻辑像素）。
///
/// 720 是桌面窗口播放最常见的视频区高度量级；用它当回退，导出件里的字幕大小与
/// 「窗口播放时看到的」大致相当。只在调用方拿不到真实显示区高度时才会用到。
const double kClipSubtitleFallbackViewportHeight = 720;

/// 字幕最多占画面宽度的比例，超出就换行。与屏幕上的 overlay 同一约定（两侧各留
/// 5% 安全边距，避免字顶到画面边缘、也避开部分电视的过扫描区）。
const double kClipSubtitleMaxWidthFraction = 0.9;

/// 一条 cue 在**导出画面像素坐标系**里的排版参数。纯数据，便于单测。
@immutable
class ClipSubtitleLayout {
  const ClipSubtitleLayout({
    required this.scale,
    required this.fontSize,
    required this.bottomPadding,
    required this.maxWidth,
    required this.shadowThickness,
  });

  /// 画面像素 / 屏幕逻辑像素。屏幕上的一切尺寸都乘它换算到导出画面上。
  final double scale;

  /// 换算后的字号（画面像素）。
  final double fontSize;

  /// 换算后的底距（画面像素）。
  final double bottomPadding;

  /// 换算后的最大行宽（画面像素），超出换行。
  final double maxWidth;

  /// 换算后的投影/描边粗细（画面像素）。
  final double shadowThickness;

  @override
  bool operator ==(Object other) =>
      other is ClipSubtitleLayout &&
      other.scale == scale &&
      other.fontSize == fontSize &&
      other.bottomPadding == bottomPadding &&
      other.maxWidth == maxWidth &&
      other.shadowThickness == shadowThickness;

  @override
  int get hashCode =>
      Object.hash(scale, fontSize, bottomPadding, maxWidth, shadowThickness);

  @override
  String toString() => 'ClipSubtitleLayout(scale: $scale, font: $fontSize, '
      'bottom: $bottomPadding, maxWidth: $maxWidth)';
}

/// 纯函数：把屏幕上的字幕样式换算成导出画面像素坐标系里的排版参数。
///
/// [viewportHeight] 是导出那一刻**屏幕上视频显示区的逻辑高度**。<=0（拿不到）时退到
/// [kClipSubtitleFallbackViewportHeight]，而不是让 scale 变成 0 或无穷——那会渲染出
/// 一张空图或把字放大到整屏，两种都比「字幕大小略有出入」糟得多。
///
/// [style] 的 `shadowThickness` 为 null 时取 [VideoSubtitleStyle.defaultShadowThickness]
/// （与屏幕上「跟随全局 UI 缩放、1.0 时用默认值」的语义一致）。
/// [overridePadding] 用于副字幕层：它有自己的位置基线
/// （[VideoSubtitleStyle.secondaryBottomPadding]，null = 跟随主层）。传入的是**逻辑
/// 像素**，与 `style.bottomPadding` 同一坐标系，同样乘 scale 换算。
ClipSubtitleLayout computeClipSubtitleLayout({
  required ClipFrameSize frame,
  required VideoSubtitleStyle style,
  required double viewportHeight,
  double? overridePadding,
}) {
  final double vh = viewportHeight > 0
      ? viewportHeight
      : kClipSubtitleFallbackViewportHeight;
  final double scale = frame.height / vh;
  final double thickness =
      style.shadowThickness ?? VideoSubtitleStyle.defaultShadowThickness;
  return ClipSubtitleLayout(
    scale: scale,
    fontSize: style.fontSize * scale,
    bottomPadding: (overridePadding ?? style.bottomPadding) * scale,
    maxWidth: frame.width * kClipSubtitleMaxWidthFraction,
    shadowThickness: thickness * scale,
  );
}

/// 把一条 cue 渲染成与 [frame] 同分辨率的全画幅 RGBA PNG 字节。
///
/// 透明底，只有字那一块不透明——`overlay` 到 `0:0` 后正好落在它在屏幕上的位置。
/// 文本为空（或全是空白）时返回 null：调用方据此跳过这条 cue，不产出一张全透明的
/// 图去白白多占一个 overlay 节点。
///
/// 渲染失败（引擎拒绝、内存不足）返回 null 而不是抛：烧不出来最多退成无字幕导出，
/// 不该让整次导出跟着失败。
/// [anchorTop] 为 true 时把文本锚到画面**顶部**（[ClipSubtitleLayout.bottomPadding]
/// 此时是离顶距离）。副字幕层用得到：主副两层在屏幕上锚在对侧（主底 → 副顶，见
/// [resolveLayerForcedAnchor]），两层都底锚会直接叠印。
Future<Uint8List?> renderClipSubtitlePng({
  required String text,
  required ClipFrameSize frame,
  required VideoSubtitleStyle style,
  required double viewportHeight,
  bool anchorTop = false,
  double? overridePadding,
  String? fontFamily,
}) async {
  if (text.trim().isEmpty) return null;
  final ClipSubtitleLayout layout = computeClipSubtitleLayout(
    frame: frame,
    style: style,
    viewportHeight: viewportHeight,
    overridePadding: overridePadding,
  );

  try {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: layout.fontSize,
          fontFamily: fontFamily,
          color: style.textColor ?? const Color(0xFFFFFFFF),
          fontWeight: _weightOf(
            style.fontWeight ?? VideoSubtitleStyle.defaultFontWeight,
          ),
          // 与屏幕上同一套柔和投影（[VideoSubtitleStyle.defaults] 的 Niratan 观感），
          // 粗细已按 scale 换算到画面像素。
          shadows: buildSubtitleSoftShadow(
            style.shadowColor ?? const Color(0xE6000000),
            layout.shadowThickness,
          ),
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: layout.maxWidth);

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    // 锚定：底锚时整块文本的下沿离画面底 bottomPadding；顶锚（副字幕层）时上沿离
    // 画面顶同样的距离。多行时 painter.height 已含全部行高，直接加减就对，不必逐行算。
    final double dy = anchorTop
        ? layout.bottomPadding
        : frame.height - layout.bottomPadding - painter.height;
    final double dx = (frame.width - painter.width) / 2;
    painter.paint(canvas, Offset(dx, dy));

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(frame.width, frame.height);
    try {
      final ByteData? png =
          await image.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
      painter.dispose();
    }
  } catch (_) {
    return null;
  }
}

/// CSS 数字字重 → Flutter [FontWeight]。越界夹到两端（`FontWeight.values` 是
/// 100..900 共 9 档）。
FontWeight _weightOf(int cssWeight) {
  final int index = (cssWeight ~/ 100) - 1;
  if (index < 0) return FontWeight.values.first;
  if (index >= FontWeight.values.length) return FontWeight.values.last;
  return FontWeight.values[index];
}
