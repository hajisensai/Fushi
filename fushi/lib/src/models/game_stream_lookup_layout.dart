import 'package:flutter/foundation.dart';

/// User-sized geometry of the stream page's lookup rail: the side panel's
/// width (wide layout), the panel's height under the video (narrow layout,
/// where the panel spans the full width) and the height of the current-line
/// area at its top (both layouts).
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
    this.compactRailHeight,
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

    final Object? compact = json['compactRailHeight'];
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
      compactRailHeight: compact is num && compact.isFinite
          ? compact.toDouble().clamp(minCompactRailHeight, maxCompactRailHeight)
          : null,
    );
  }

  static const double defaultRailWidth = 360;
  static const double minRailWidth = 280;
  static const double maxRailWidth = 720;

  /// The video keeps at least this much width beside the rail: enough for
  /// the on-screen pad's two button clusters side by side.
  static const double minVideoWidth = 360;

  /// Narrow-layout panel height before the user resized it: this share of
  /// the body height, capped at [defaultCompactRailCap] (the pre-resize
  /// behaviour).
  static const double defaultCompactRailFraction = 0.5;
  static const double defaultCompactRailCap = 360;
  static const double minCompactRailHeight = 200;
  static const double maxCompactRailHeight = 720;

  /// Above the narrow-layout panel the video keeps at least this much height:
  /// enough for the on-screen pad's shoulder row and D-pad cluster.
  static const double minVideoHeight = 280;

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

  /// Narrow-layout panel height; null until the user resizes it, so the
  /// default keeps following the screen height.
  final double? compactRailHeight;

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

  /// Tallest narrow-layout panel that still leaves [minVideoHeight] for the
  /// video when both share [bodyHeight]; never below [minCompactRailHeight].
  static double compactRailHeightLimit(double bodyHeight) =>
      (bodyHeight - minVideoHeight).clamp(
        minCompactRailHeight,
        maxCompactRailHeight,
      );

  /// Whether a narrow-layout body [bodyHeight] tall holds both the panel's
  /// and the video's minimum, i.e. whether the panel height is the user's to
  /// choose. A landscape phone with the soft keyboard up has far less.
  static bool compactRailResizable(double bodyHeight) =>
      bodyHeight >= minCompactRailHeight + minVideoHeight;

  /// The narrow-layout panel height actually used when video and panel share
  /// [bodyHeight].
  ///
  /// A body too short for both minimums (see [compactRailResizable]) falls
  /// back to the pre-resize split, half the body: a fixed 200 floor would be
  /// taller than such a body and overflow it (BUG-3253).
  double effectiveCompactRailHeight(double bodyHeight) {
    if (!compactRailResizable(bodyHeight)) {
      final double body = bodyHeight < 0 ? 0 : bodyHeight;
      return body * defaultCompactRailFraction;
    }
    return (compactRailHeight ??
            (bodyHeight * defaultCompactRailFraction).clamp(
              0,
              defaultCompactRailCap,
            ))
        .clamp(minCompactRailHeight, compactRailHeightLimit(bodyHeight));
  }

  /// The rail width actually used in a body [bodyWidth] wide.
  double effectiveRailWidth(double bodyWidth) =>
      railWidth.clamp(minRailWidth, railWidthLimit(bodyWidth));

  /// The line height actually used in a rail [railHeight] tall.
  double effectiveLineHeight(double railHeight) =>
      lineHeight.clamp(minLineHeight, lineHeightLimit(railHeight));

  GameStreamLookupLayout copyWith({
    double? railWidth,
    double? lineHeight,
    double? compactRailHeight,
  }) => GameStreamLookupLayout(
    railWidth: railWidth ?? this.railWidth,
    lineHeight: lineHeight ?? this.lineHeight,
    compactRailHeight: compactRailHeight ?? this.compactRailHeight,
  );

  Map<String, double> toJson() => <String, double>{
    'railWidth': railWidth,
    'lineHeight': lineHeight,
    if (compactRailHeight != null) 'compactRailHeight': compactRailHeight!,
  };

  @override
  bool operator ==(Object other) =>
      other is GameStreamLookupLayout &&
      other.railWidth == railWidth &&
      other.lineHeight == lineHeight &&
      other.compactRailHeight == compactRailHeight;

  @override
  int get hashCode => Object.hash(railWidth, lineHeight, compactRailHeight);

  @override
  String toString() =>
      'GameStreamLookupLayout(railWidth: $railWidth, lineHeight: $lineHeight, '
      'compactRailHeight: $compactRailHeight)';
}
