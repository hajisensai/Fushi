/// 智能遮布的纯几何与迟滞：把一次抽样识别出的行框变成「现在该盖哪儿」。
///
/// 坐标一律是视频画面的比例坐标（0..1）。不碰 Flutter / 播放器，单测直接喂样本。
/// 设计见 `docs/specs/2026-11-20-video-desub-design.md` §3。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

/// 行框四周的留边（按行高的倍数）：横向多留，盖住描边、阴影与识别框没框到的首尾字。
const double kSmartSubtitleMaskPadX = 0.6;
const double kSmartSubtitleMaskPadY = 0.35;

/// 行框高度下限（画面高度比例）：再小的框多半是噪点，不当字幕。
const double kSmartSubtitleMaskMinLineHeight = 0.012;

/// 本帧所有字幕行 → 遮布矩形：行框留边后取并集，再钳进搜索区域 [region]。
///
/// 只认中心落在 [region] 里、高度不小于 [kSmartSubtitleMaskMinLineHeight] 的行；
/// 一行都不剩返回 null。
Rect? smartSubtitleMaskRectForLines(List<Rect> lines, Rect region) {
  Rect? union;
  for (final Rect line in lines) {
    if (line.height < kSmartSubtitleMaskMinLineHeight || line.width <= 0) {
      continue;
    }
    if (!region.contains(line.center)) continue;
    final Rect padded = line.inflateXY(
      line.height * kSmartSubtitleMaskPadX,
      line.height * kSmartSubtitleMaskPadY,
    );
    union = union == null ? padded : union.expandToInclude(padded);
  }
  if (union == null) return null;
  final Rect clamped = union.intersect(region);
  return clamped.isEmpty ? null : clamped;
}

extension on Rect {
  Rect inflateXY(double dx, double dy) =>
      Rect.fromLTRB(left - dx, top - dy, right + dx, bottom + dy);
}

/// 迟滞：有字立刻显示；连续无字超过 [holdEmpty] 才隐藏（句间空档不闪）。
class SmartSubtitleMaskTracker {
  SmartSubtitleMaskTracker({required this.holdEmpty});

  final Duration holdEmpty;

  Rect? _rect;
  Duration? _lastHit;

  /// 当前该盖的矩形；null = 不显示。
  Rect? get rect => _rect;

  /// 喂一次抽样：[lines] 是这一帧识别出的横排行框，[at] 是单调时钟时间。返回新的
  /// [rect]。
  Rect? addSample({
    required List<Rect> lines,
    required Rect region,
    required Duration at,
  }) {
    final Rect? hit = smartSubtitleMaskRectForLines(lines, region);
    if (hit != null) {
      _lastHit = at;
      return _rect = hit;
    }
    final Duration? last = _lastHit;
    if (last == null || at - last >= holdEmpty) {
      _lastHit = null;
      _rect = null;
    }
    return _rect;
  }

  /// 画面不连续（seek / 换集 / 换搜索区域）：清空，等下一次识别。
  void reset() {
    _rect = null;
    _lastHit = null;
  }
}

/// 两个矩形是否「几乎一样」（每条边差不超过 [tolerance]）——避免识别框的像素级抖动
/// 触发遮布动画。
bool smartSubtitleMaskRectsClose(Rect a, Rect b, {double tolerance = 0.006}) =>
    math.max(
      math.max((a.left - b.left).abs(), (a.top - b.top).abs()),
      math.max((a.right - b.right).abs(), (a.bottom - b.bottom).abs()),
    ) <=
    tolerance;
