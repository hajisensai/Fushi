import 'package:flutter/foundation.dart';

/// User-sized geometry of the stream page's lookup rail: the side panel's
/// width and the height of the current-line area at its top.
///
/// The line text's font size follows the line area's height, so dragging the
/// area's bottom edge zooms the line. One gesture fixes the actual complaint
/// (glyphs too small to tap on a tablet) without a second size control.
///
/// Stored per device: the right size depends on the screen it runs on, so a
/// tablet's choice must not follow a backup to a phone or a desktop.
@immutable
class GameStreamLookupLayout {
  const GameStreamLookupLayout({
    this.railWidth = defaultRailWidth,
    this.lineHeight = defaultLineHeight,
  });

  /// Decodes a stored value. Missing or malformed fields fall back to their
  /// default; out-of-range values are clamped to the absolute limits.
  factory GameStreamLookupLayout.fromJson(Object? json) {
    if (json is! Map) return const GameStreamLookupLayout();
    double read(String key, double fallback, double min, double max) {
      final Object? value = json[key];
      if (value is! num || !value.isFinite) return fallback;
      return value.toDouble().clamp(min, max);
    }

    return GameStreamLookupLayout(
      railWidth: read(
        'railWidth',
        defaultRailWidth,
        minRailWidth,
        maxRailWidth,
      ),
      lineHeight: read(
        'lineHeight',
        defaultLineHeight,
        minLineHeight,
        maxLineHeight,
      ),
    );
  }

  static const double defaultRailWidth = 360;
  static const double minRailWidth = 280;
  static const double maxRailWidth = 720;

  /// The video keeps at least this much width beside the rail: enough for
  /// the on-screen pad's two button clusters side by side.
  static const double minVideoWidth = 360;

  static const double defaultLineHeight = 140;
  static const double minLineHeight = 96;
  static const double maxLineHeight = 480;

  /// The dictionary below the line area keeps at least this much height.
  static const double minDictionaryHeight = 120;

  /// Line font size at [defaultLineHeight] (the size before the area was
  /// resizable).
  static const double baseFontSize = 14;
  static const double minFontSize = 12;
  static const double maxFontSize = 40;

  /// Step for one arrow key press on a focused resize handle.
  static const double keyboardStep = 16;

  final double railWidth;
  final double lineHeight;

  /// Line text size for a line area [height] tall.
  static double fontSizeFor(double height) =>
      (baseFontSize * height / defaultLineHeight).clamp(
        minFontSize,
        maxFontSize,
      );

  /// Widest rail that still leaves [minVideoWidth] for the video when video
  /// and rail share [bodyWidth]; never below [minRailWidth].
  static double railWidthLimit(double bodyWidth) =>
      (bodyWidth - minVideoWidth).clamp(minRailWidth, maxRailWidth);

  /// Tallest line area that still leaves [minDictionaryHeight] for the
  /// dictionary in a rail [railHeight] tall; never below [minLineHeight].
  static double lineHeightLimit(double railHeight) =>
      (railHeight - minDictionaryHeight).clamp(minLineHeight, maxLineHeight);

  /// The rail width actually used in a body [bodyWidth] wide.
  double effectiveRailWidth(double bodyWidth) =>
      railWidth.clamp(minRailWidth, railWidthLimit(bodyWidth));

  /// The line height actually used in a rail [railHeight] tall.
  double effectiveLineHeight(double railHeight) =>
      lineHeight.clamp(minLineHeight, lineHeightLimit(railHeight));

  GameStreamLookupLayout copyWith({double? railWidth, double? lineHeight}) =>
      GameStreamLookupLayout(
        railWidth: railWidth ?? this.railWidth,
        lineHeight: lineHeight ?? this.lineHeight,
      );

  Map<String, double> toJson() => <String, double>{
    'railWidth': railWidth,
    'lineHeight': lineHeight,
  };

  @override
  bool operator ==(Object other) =>
      other is GameStreamLookupLayout &&
      other.railWidth == railWidth &&
      other.lineHeight == lineHeight;

  @override
  int get hashCode => Object.hash(railWidth, lineHeight);

  @override
  String toString() =>
      'GameStreamLookupLayout(railWidth: $railWidth, lineHeight: $lineHeight)';
}
