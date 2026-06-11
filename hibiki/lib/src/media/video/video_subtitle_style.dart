import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

/// media_kit 默认底部控制条（进度条 + 按钮条）在视频底部占据的高度（逻辑像素）。
///
/// 来源是 media_kit `MaterialVideoControlsThemeData` 的默认布局：底部按钮条本体
/// [bottomButtonBarMargin] 的垂直外边距（默认 `bottom: 42`，vertical=42）加上按钮条
/// 高度（默认 `buttonBarHeight: 56`，Hibiki 两端主题都钉同值）。media_kit 自带字幕
/// 视图正是用这个量（`subtitleVerticalShiftOffset = padding.bottom + bottomButtonBarMargin.vertical
/// + buttonBarHeight`）在控制条显示时把字幕上推、避开进度条。
///
/// Hibiki 用自绘 `VideoSubtitleOverlay`（非 media_kit 内置字幕视图）。TODO-129 起字幕
/// **动态**避让：控制条出现时把字幕在用户位置之上额外上顶本值、隐藏时落回用户位置
/// （由 [VideoSubtitleOverlay] 的 `controlsVisible` 驱动 `AnimatedPadding`），不再像
/// TODO-089 那样把本值恒加进默认 [VideoSubtitleStyle.bottomPadding]。本常量现在是
/// 「控制条可见时的避让高度」，不再是默认抬升的下限。Hibiki 的两套控制主题都未覆盖
/// 这两项 margin，故仍走 media_kit 默认几何（与之同源）。
const double kVideoControlsBottomReserve = 42 + 56;

/// Video subtitle appearance persisted as app preferences.
///
/// The default is a high-contrast caption look: fixed white text with a thick
/// black outline/shadow so it stays readable on any video regardless of the
/// active app theme (TODO-051). Weight and shadow thickness stay nullable so the
/// default thickness can follow the global UI size, while explicit user choices
/// remain fixed. [textColor]/[shadowColor] left null means "follow the theme"
/// (legacy data persisted before TODO-051), resolved via [resolveTextColor] /
/// [resolveShadowColor].
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
  static const double defaultShadowThickness = 5;

  /// v1 持久化时代硬编码的默认阴影粗细（3px）。仅供 [decode] 把 v1 存的
  /// 该值迁移成 null（跟随 UI scale）用，不参与当前外观（当前默认是
  /// [defaultShadowThickness]=5）。与当前常量解耦，改默认不破坏旧数据迁移。
  static const double _v1LegacyShadowThickness = 3;

  /// High-contrast caption defaults (TODO-051): 36px bold WHITE text with a
  /// thick BLACK outline/shadow, no box. Fixed white/black instead of theme
  /// colors so subtitles stay legible on any video and don't wash out on
  /// low-contrast themes. [fontWeight]/[shadowThickness] stay null to follow the
  /// global UI scale ([defaultFontWeight] / [defaultShadowThickness] at 1.0).
  ///
  /// [bottomPadding] is the user's subtitle position only (default 75). It no
  /// longer bakes in the controls-bar clearance: TODO-129 made the self-drawn
  /// [VideoSubtitleOverlay] dodge the bar *dynamically* — when the controls show
  /// it lifts an extra [kVideoControlsBottomReserve] above this position and
  /// drops back when they hide (driven by `controlsVisible`). So the default
  /// stays at the natural 75 and is only pushed up while the progress bar is
  /// actually on screen, instead of being permanently raised (TODO-089). Users
  /// who manually pick a position keep their value verbatim (no "is-manual"
  /// branch — it's the same field; the dynamic dodge stacks on top of it).
  static const VideoSubtitleStyle defaults = VideoSubtitleStyle(
    fontSize: 36,
    textColor: Color(0xFFFFFFFF),
    fontWeight: null,
    shadowColor: Color(0xFF000000),
    shadowThickness: null,
    backgroundColor: null,
    backgroundOpacity: 0,
    // 用户位置基线（不含控制条避让）：避让在控制条可见时由 overlay 动态叠加（TODO-129）。
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
        // v1 数据存的是当时硬编码的默认阴影粗细（3px）= 「跟随 UI scale」，迁移成 null。
        // 用 v1 时代的字面值对照，而非当前 [defaultShadowThickness]（TODO-051 已改为
        // 5），否则改默认会把老用户的 3px 误当显式值钉死、不再跟随缩放。
        return version < 2 && normalized == _v1LegacyShadowThickness
            ? null
            : normalized;
      }

      // Colors round-trip verbatim: a stored ARGB int is honoured as an explicit
      // choice, a missing/null value stays null = "follow the theme" (legacy
      // data persisted before TODO-051, when defaults were theme-following).
      // White (0xFFFFFFFF) is the new default text color (TODO-051) and must
      // persist as an explicit value — no longer folded back to null.
      final int? argb = colorArgb(d['textColor']);
      final int? shadowArgb = colorArgb(d['shadowColor']);
      final int? backgroundArgb = colorArgb(d['backgroundColor']);
      return VideoSubtitleStyle(
        fontSize: num2d(d['fontSize'], defaults.fontSize).clamp(10, 72),
        textColor: argb == null ? null : Color(argb),
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
