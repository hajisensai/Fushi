import 'dart:convert';

import 'package:flutter/material.dart';

/// 视频字幕外观（全局偏好）。默认值刻意等于历史硬编码外观，未设置时观感不变。
@immutable
class VideoSubtitleStyle {
  const VideoSubtitleStyle({
    required this.fontSize,
    required this.textColor,
    required this.fontWeight,
    required this.shadowColor,
    required this.shadowThickness,
    required this.backgroundColor,
    required this.backgroundOpacity,
    required this.bottomPadding,
  });

  /// asbplayer-style defaults: 36px bold white text, no box, black shadow.
  static const VideoSubtitleStyle defaults = VideoSubtitleStyle(
    fontSize: 36,
    textColor: null,
    fontWeight: 700,
    shadowColor: null,
    shadowThickness: 3,
    backgroundColor: null,
    backgroundOpacity: 0,
    bottomPadding: 75,
  );

  final double fontSize;
  final Color? textColor;
  final int fontWeight;
  final Color? shadowColor;
  final double shadowThickness;
  final Color? backgroundColor;
  final double backgroundOpacity;
  final double bottomPadding;

  VideoSubtitleStyle copyWith({
    double? fontSize,
    Color? textColor,
    int? fontWeight,
    Color? shadowColor,
    double? shadowThickness,
    Color? backgroundColor,
    double? backgroundOpacity,
    double? bottomPadding,
  }) {
    return VideoSubtitleStyle(
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      fontWeight: fontWeight ?? this.fontWeight,
      shadowColor: shadowColor ?? this.shadowColor,
      shadowThickness: shadowThickness ?? this.shadowThickness,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      bottomPadding: bottomPadding ?? this.bottomPadding,
    );
  }

  Color resolveTextColor(Color themeColor) => textColor ?? themeColor;
  Color resolveShadowColor(Color themeColor) => shadowColor ?? themeColor;
  Color resolveBackgroundColor(Color themeColor) =>
      backgroundColor ?? themeColor;

  /// 编码为持久化 JSON 字符串。纯函数。
  static String encode(VideoSubtitleStyle s) => jsonEncode(<String, dynamic>{
        'fontSize': s.fontSize,
        'textColor': s.textColor?.toARGB32(),
        'fontWeight': s.fontWeight,
        'shadowColor': s.shadowColor?.toARGB32(),
        'shadowThickness': s.shadowThickness,
        'backgroundColor': s.backgroundColor?.toARGB32(),
        'backgroundOpacity': s.backgroundOpacity,
        'bottomPadding': s.bottomPadding,
      });

  /// 解码（容错：null/空/非法 → [defaults]；越界 clamp）。纯函数。
  static VideoSubtitleStyle decode(String? json) {
    if (json == null || json.isEmpty) return defaults;
    try {
      final dynamic d = jsonDecode(json);
      if (d is! Map) return defaults;
      double num2d(Object? v, double fb) => v is num ? v.toDouble() : fb;
      int num2i(Object? v, int fb) => v is num ? v.round() : fb;
      int? colorArgb(Object? v) => v is num ? v.toInt() : null;
      int normalizeWeight(Object? v) {
        final int raw = num2i(v, defaults.fontWeight);
        final int rounded = (raw / 100).round() * 100;
        if (rounded < 100) return 100;
        if (rounded > 900) return 900;
        return rounded;
      }

      final int? argb =
          d['textColor'] is num ? (d['textColor'] as num).toInt() : null;
      final int? shadowArgb = colorArgb(d['shadowColor']);
      final int? backgroundArgb = colorArgb(d['backgroundColor']);
      return VideoSubtitleStyle(
        fontSize: num2d(d['fontSize'], defaults.fontSize).clamp(10, 72),
        textColor: argb == null || argb == 0xFFFFFFFF ? null : Color(argb),
        fontWeight: normalizeWeight(d['fontWeight']),
        shadowColor: shadowArgb == null ? null : Color(shadowArgb),
        shadowThickness:
            num2d(d['shadowThickness'], defaults.shadowThickness).clamp(0, 12),
        backgroundColor: backgroundArgb == null ? null : Color(backgroundArgb),
        backgroundOpacity: num2d(
          d['backgroundOpacity'],
          defaults.backgroundOpacity,
        ).clamp(0.0, 1.0),
        bottomPadding:
            num2d(d['bottomPadding'], defaults.bottomPadding).clamp(0, 400),
      );
    } catch (_) {
      return defaults;
    }
  }
}
