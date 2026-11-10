/// 视频「字幕遮布」的纯数据部分：外观枚举、配置（偏好 `video_subtitle_mask` 的 JSON
/// 形态）与比例矩形钳制。只依赖 `dart:convert` / `dart:ui`，偏好仓库与 AppModel
/// 只 import 这里——遮布的 widget / 几何换算（会拖进图形字幕 OCR 链路）留在
/// `video_subtitle_mask.dart`，只由视频页消费，免得底层偏好层的 import 闭包回连 AppModel
/// （守卫 test/build/import_cycle_guard_test.dart）。
library;

import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart' show immutable;

/// 遮布外观。
enum VideoSubtitleMaskStyle {
  /// 背景模糊（默认）：糊开字形，画面色调仍在，观感最轻。
  blur,

  /// 纯色块：彻底挡住，强度 = 不透明度。
  solid,
}

/// 遮布最小边长（画面比例），防止缩成看不见、抓不住的一条线。
const double kVideoSubtitleMaskMinFraction = 0.03;

/// 遮布配置（偏好 `video_subtitle_mask` 的 JSON 形态）。
@immutable
class VideoSubtitleMaskConfig {
  const VideoSubtitleMaskConfig({
    this.enabled = false,
    this.rect = kDefaultRect,
    this.style = VideoSubtitleMaskStyle.blur,
    this.strength = 0.85,
  });

  /// 默认摆在画面底部居中、约一行硬字幕高——中文内嵌字幕最常见的位置。
  static const Rect kDefaultRect = Rect.fromLTWH(0.15, 0.82, 0.7, 0.12);

  final bool enabled;

  /// 画面内容区比例坐标（0..1）。
  final Rect rect;
  final VideoSubtitleMaskStyle style;

  /// 0..1：模糊时映射成模糊半径，纯色时就是不透明度。
  final double strength;

  VideoSubtitleMaskConfig copyWith({
    bool? enabled,
    Rect? rect,
    VideoSubtitleMaskStyle? style,
    double? strength,
  }) => VideoSubtitleMaskConfig(
    enabled: enabled ?? this.enabled,
    rect: rect == null ? this.rect : clampVideoSubtitleMaskRect(rect),
    style: style ?? this.style,
    strength: (strength ?? this.strength).clamp(0.0, 1.0),
  );

  String toJson() => jsonEncode(<String, Object>{
    'enabled': enabled,
    'l': rect.left,
    't': rect.top,
    'w': rect.width,
    'h': rect.height,
    'style': style.name,
    'strength': strength,
  });

  /// 解析偏好；缺字段 / 坏值逐项回落默认，整串坏掉回落整份默认。
  static VideoSubtitleMaskConfig fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const VideoSubtitleMaskConfig();
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return const VideoSubtitleMaskConfig();
      }
      double readNum(String key, double fallback) {
        final Object? v = decoded[key];
        return v is num && v.isFinite ? v.toDouble() : fallback;
      }

      const Rect d = kDefaultRect;
      final Object? styleName = decoded['style'];
      return VideoSubtitleMaskConfig(
        enabled: decoded['enabled'] == true,
        rect: clampVideoSubtitleMaskRect(
          Rect.fromLTWH(
            readNum('l', d.left),
            readNum('t', d.top),
            readNum('w', d.width),
            readNum('h', d.height),
          ),
        ),
        style: VideoSubtitleMaskStyle.values.firstWhere(
          (VideoSubtitleMaskStyle s) => s.name == styleName,
          orElse: () => VideoSubtitleMaskStyle.blur,
        ),
        strength: readNum('strength', 0.85).clamp(0.0, 1.0),
      );
    } on FormatException {
      return const VideoSubtitleMaskConfig();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is VideoSubtitleMaskConfig &&
      other.enabled == enabled &&
      other.rect == rect &&
      other.style == style &&
      other.strength == strength;

  @override
  int get hashCode => Object.hash(enabled, rect, style, strength);
}

/// 把比例矩形钳进画面：尺寸不小于 [kVideoSubtitleMaskMinFraction]、不大于整幅，
/// 位置平移回 0..1 内（保尺寸、只挪位置）。
Rect clampVideoSubtitleMaskRect(Rect r) {
  const double min = kVideoSubtitleMaskMinFraction;
  final double w = r.width.isFinite ? r.width.clamp(min, 1.0) : min;
  final double h = r.height.isFinite ? r.height.clamp(min, 1.0) : min;
  final double l = r.left.isFinite ? r.left.clamp(0.0, 1.0 - w) : 0.0;
  final double t = r.top.isFinite ? r.top.clamp(0.0, 1.0 - h) : 0.0;
  return Rect.fromLTWH(l, t, w, h);
}
