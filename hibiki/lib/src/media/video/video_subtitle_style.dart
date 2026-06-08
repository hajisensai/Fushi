import 'dart:convert';

import 'package:flutter/material.dart';

/// 视频字幕外观（全局偏好）。默认值刻意等于历史硬编码外观，未设置时观感不变。
@immutable
class VideoSubtitleStyle {
  const VideoSubtitleStyle({
    required this.fontSize,
    required this.textColor,
    required this.backgroundOpacity,
    required this.bottomPadding,
  });

  /// asbplayer-style defaults: 36px bold white text, no box, black shadow.
  static const VideoSubtitleStyle defaults = VideoSubtitleStyle(
    fontSize: 36,
    textColor: Color(0xFFFFFFFF),
    backgroundOpacity: 0,
    bottomPadding: 75,
  );

  final double fontSize;
  final Color textColor;
  final double backgroundOpacity;
  final double bottomPadding;

  VideoSubtitleStyle copyWith({
    double? fontSize,
    Color? textColor,
    double? backgroundOpacity,
    double? bottomPadding,
  }) {
    return VideoSubtitleStyle(
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      bottomPadding: bottomPadding ?? this.bottomPadding,
    );
  }

  /// 编码为持久化 JSON 字符串。纯函数。
  static String encode(VideoSubtitleStyle s) => jsonEncode(<String, dynamic>{
        'fontSize': s.fontSize,
        'textColor': s.textColor.toARGB32(),
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
      final int argb =
          d['textColor'] is num ? (d['textColor'] as num).toInt() : 0xFFFFFFFF;
      return VideoSubtitleStyle(
        fontSize: num2d(d['fontSize'], defaults.fontSize).clamp(10, 72),
        textColor: Color(argb),
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
