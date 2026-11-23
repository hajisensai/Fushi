/// 素材包里每张图的摆放（folia 凝彩 `TemperaLayerImage` 的 align / verticalAlign / scale / opacity）：
/// 用户在参数面板的素材包行里逐张设，存在包目录的 `placement.json`（`lyric_visualizer_assets.dart`）。
/// 图片池是「倾向」不是精确坐标：样式按种子在对应的带里取位置（folia `resolveTemperaImagePlacement`）。
library;

import 'package:flutter/foundation.dart' show immutable;

/// 横向倾向。[wire] 落盘（冻结，与 folia 同名）。
enum LyricVisualizerAssetAlign {
  free('free'),
  left('left'),
  center('center'),
  right('right');

  const LyricVisualizerAssetAlign(this.wire);

  final String wire;

  static LyricVisualizerAssetAlign? fromWire(Object? v) {
    for (final LyricVisualizerAssetAlign a in values) {
      if (a.wire == v) return a;
    }
    return null;
  }
}

/// 纵向倾向。[wire] 落盘（冻结，与 folia 同名）。
enum LyricVisualizerAssetVerticalAlign {
  free('free'),
  top('top'),
  center('center'),
  bottom('bottom');

  const LyricVisualizerAssetVerticalAlign(this.wire);

  final String wire;

  static LyricVisualizerAssetVerticalAlign? fromWire(Object? v) {
    for (final LyricVisualizerAssetVerticalAlign a in values) {
      if (a.wire == v) return a;
    }
    return null;
  }
}

/// 一张图的摆放。
@immutable
class LyricVisualizerAssetPlacement {
  const LyricVisualizerAssetPlacement({
    this.align = LyricVisualizerAssetAlign.free,
    this.verticalAlign = LyricVisualizerAssetVerticalAlign.bottom,
    this.scale = 0.7,
    this.opacity = 1,
  });

  /// folia `DEFAULT_TEMPERA_LAYER_IMAGE`：横向自由、靠下、高 0.7 屏、不透明。
  static const LyricVisualizerAssetPlacement defaults =
      LyricVisualizerAssetPlacement();

  static const double minScale = 0.05;
  static const double maxScale = 2;

  final LyricVisualizerAssetAlign align;
  final LyricVisualizerAssetVerticalAlign verticalAlign;

  /// 图高占画面高的比例（宽按原图比例）。
  final double scale;
  final double opacity;

  /// 横向取位的带（画面宽的比例，folia `ALIGN_BANDS`）。
  (double, double) get horizontalBand => switch (align) {
    LyricVisualizerAssetAlign.left => (0.14, 0.32),
    LyricVisualizerAssetAlign.center => (0.4, 0.6),
    LyricVisualizerAssetAlign.right => (0.68, 0.86),
    LyricVisualizerAssetAlign.free => (0.12, 0.88),
  };

  /// 纵向取位的带（画面高的比例，folia `VERTICAL_ALIGN_BANDS`）。
  (double, double) get verticalBand => switch (verticalAlign) {
    LyricVisualizerAssetVerticalAlign.top => (0.14, 0.32),
    LyricVisualizerAssetVerticalAlign.center => (0.4, 0.6),
    LyricVisualizerAssetVerticalAlign.bottom => (0.68, 0.86),
    LyricVisualizerAssetVerticalAlign.free => (0.12, 0.88),
  };

  LyricVisualizerAssetPlacement copyWith({
    LyricVisualizerAssetAlign? align,
    LyricVisualizerAssetVerticalAlign? verticalAlign,
    double? scale,
    double? opacity,
  }) => LyricVisualizerAssetPlacement(
    align: align ?? this.align,
    verticalAlign: verticalAlign ?? this.verticalAlign,
    scale: scale ?? this.scale,
    opacity: opacity ?? this.opacity,
  );

  Map<String, Object> toJson() => <String, Object>{
    'align': align.wire,
    'verticalAlign': verticalAlign.wire,
    'scale': scale,
    'opacity': opacity,
  };

  /// 坏值逐项回落 [fallback]（数值钳到合法范围）。
  static LyricVisualizerAssetPlacement fromJson(
    Object? json, {
    LyricVisualizerAssetPlacement fallback = defaults,
  }) {
    if (json is! Map) return fallback;
    final Object? s = json['scale'];
    final Object? o = json['opacity'];
    return LyricVisualizerAssetPlacement(
      align:
          LyricVisualizerAssetAlign.fromWire(json['align']) ?? fallback.align,
      verticalAlign:
          LyricVisualizerAssetVerticalAlign.fromWire(json['verticalAlign']) ??
          fallback.verticalAlign,
      scale: s is num && s.isFinite
          ? s.toDouble().clamp(minScale, maxScale)
          : fallback.scale,
      opacity: o is num && o.isFinite
          ? o.toDouble().clamp(0.0, 1.0)
          : fallback.opacity,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerAssetPlacement &&
      other.align == align &&
      other.verticalAlign == verticalAlign &&
      other.scale == scale &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(align, verticalAlign, scale, opacity);
}
