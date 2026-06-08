import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

/// Video subtitle appearance persisted as app preferences.
///
/// The asbplayer visual baseline is resolved at app UI scale 1.0. Weight and
/// shadow thickness stay nullable so the default can follow the global UI size,
/// while explicit user choices remain fixed.
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

  static const int defaultFontWeight = 700;
  static const double defaultShadowThickness = 3;

  /// asbplayer-style defaults: 36px bold themed text, no box, themed shadow.
  static const VideoSubtitleStyle defaults = VideoSubtitleStyle(
    fontSize: 36,
    textColor: null,
    fontWeight: null,
    shadowColor: null,
    shadowThickness: null,
    backgroundColor: null,
    backgroundOpacity: 0,
    bottomPadding: 75,
  );

  final double fontSize;
  final Color? textColor;
  final int? fontWeight;
  final Color? shadowColor;
  final double? shadowThickness;
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

  int resolveFontWeight(double uiScale) {
    if (fontWeight != null) return fontWeight!;
    final double scale = _normalizeUiScale(uiScale);
    final int rounded = (defaultFontWeight * scale / 100).round() * 100;
    if (rounded < 100) return 100;
    if (rounded > 900) return 900;
    return rounded;
  }

  double resolveShadowThickness(double uiScale) {
    if (shadowThickness != null) return shadowThickness!;
    return (defaultShadowThickness * _normalizeUiScale(uiScale))
        .clamp(0, 12)
        .toDouble();
  }

  static String encode(VideoSubtitleStyle s) => jsonEncode(<String, dynamic>{
        '_v': 2,
        'fontSize': s.fontSize,
        'textColor': s.textColor?.toARGB32(),
        'fontWeight': s.fontWeight,
        'shadowColor': s.shadowColor?.toARGB32(),
        'shadowThickness': s.shadowThickness,
        'backgroundColor': s.backgroundColor?.toARGB32(),
        'backgroundOpacity': s.backgroundOpacity,
        'bottomPadding': s.bottomPadding,
      });

  static VideoSubtitleStyle decode(String? json) {
    if (json == null || json.isEmpty) return defaults;
    try {
      final dynamic d = jsonDecode(json);
      if (d is! Map) return defaults;
      final int version = d['_v'] is num ? (d['_v'] as num).round() : 1;
      double num2d(Object? v, double fallback) =>
          v is num ? v.toDouble() : fallback;
      int? colorArgb(Object? v) => v is num ? v.toInt() : null;
      int normalizeWeight(Object? v) {
        final int raw = v is num ? v.round() : defaultFontWeight;
        final int rounded = (raw / 100).round() * 100;
        if (rounded < 100) return 100;
        if (rounded > 900) return 900;
        return rounded;
      }

      int? readFontWeight(Object? v) {
        if (v is! num) return null;
        final int normalized = normalizeWeight(v);
        return version < 2 && normalized == defaultFontWeight
            ? null
            : normalized;
      }

      double? readShadowThickness(Object? v) {
        if (v is! num) return null;
        final double normalized = v.toDouble().clamp(0, 12).toDouble();
        return version < 2 && normalized == defaultShadowThickness
            ? null
            : normalized;
      }

      final int? argb =
          d['textColor'] is num ? (d['textColor'] as num).toInt() : null;
      final int? shadowArgb = colorArgb(d['shadowColor']);
      final int? backgroundArgb = colorArgb(d['backgroundColor']);
      return VideoSubtitleStyle(
        fontSize: num2d(d['fontSize'], defaults.fontSize).clamp(10, 72),
        textColor: argb == null || argb == 0xFFFFFFFF ? null : Color(argb),
        fontWeight: readFontWeight(d['fontWeight']),
        shadowColor: shadowArgb == null ? null : Color(shadowArgb),
        shadowThickness: readShadowThickness(d['shadowThickness']),
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

  static double _normalizeUiScale(double uiScale) {
    return HibikiAppUiScale.normalize(uiScale);
  }
}
