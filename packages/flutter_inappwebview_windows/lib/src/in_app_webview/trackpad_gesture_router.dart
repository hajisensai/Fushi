import 'dart:math' as math;
import 'dart:ui';

/// 触控板两指手势（Flutter 的 PointerPanZoom 序列）转给 WebView2 的方式。
enum TrackpadGestureKind { scroll, pinch }

/// 一次 PanZoomUpdate 应转发的内容。
class TrackpadGestureOutput {
  const TrackpadGestureOutput.scroll(Offset delta)
    : kind = TrackpadGestureKind.scroll,
      scrollDelta = delta,
      pinchWheelDelta = 0;

  const TrackpadGestureOutput.pinch(double wheelDelta)
    : kind = TrackpadGestureKind.pinch,
      scrollDelta = Offset.zero,
      pinchWheelDelta = wheelDelta;

  final TrackpadGestureKind kind;

  /// [TrackpadGestureKind.scroll]：逻辑像素滚动量。
  final Offset scrollDelta;

  /// [TrackpadGestureKind.pinch]：Ctrl+滚轮的 deltaY，Chromium 口径
  /// `-100·ln(本次缩放比)`，页面按 `exp(-deltaY/100)` 还原比例。
  final double pinchWheelDelta;
}

/// 一次触控板手势只归一种语义：滚动或捏合。
///
/// BUG-2758：精密触控板的两指手势在 Flutter 里是同时带 `panDelta` 与 `scale`
/// 的 PointerPanZoomUpdate。此前只把 `panDelta` 当普通滚轮转给 WebView2、
/// `scale` 整个丢掉——两指捏合时指尖中点的抖动被当成上下滚动，缩放却永远到
/// 不了页面（条漫里「捏合变成上下滑」，跨页模式下还会被滚轮翻页）。
///
/// 真浏览器（Chromium + DirectManipulation）的做法：捏合合成为带 Ctrl 的滚轮，
/// 且捏合期间不再滚动。这里同口径：缩放偏离 1 超过 [pinchScaleThreshold]
/// 即判为捏合，此后到手势结束只发缩放、不发平移；从未越过阈值的手势是纯滚动。
class TrackpadGestureRouter {
  /// 两指滚动时 DirectManipulation 报的 scale 恒在 1 附近，捏合一开始就
  /// 明显偏离；3% 足以滤掉滚动抖动，又不至于吃掉捏合的起手。
  static const double pinchScaleThreshold = 0.03;

  double _pinchBaseScale = 1.0;
  bool _pinching = false;

  bool get isPinching => _pinching;

  /// PointerPanZoomStart：新手势从未分类状态开始。
  void start() {
    _pinchBaseScale = 1.0;
    _pinching = false;
  }

  /// PointerPanZoomUpdate。[scale] 是自手势开始的累计缩放。
  TrackpadGestureOutput update({
    required Offset panDelta,
    required double scale,
  }) {
    if (!_pinching && (scale - 1.0).abs() >= pinchScaleThreshold) {
      _pinching = true;
    }
    if (!_pinching) return TrackpadGestureOutput.scroll(panDelta);
    // 基准在判定前恒为 1，越过阈值那一下把已攒的缩放一次交出去，起手不丢。
    final double ratio = scale / _pinchBaseScale;
    _pinchBaseScale = scale;
    if (!(ratio > 0) || !ratio.isFinite) {
      return const TrackpadGestureOutput.pinch(0);
    }
    return TrackpadGestureOutput.pinch(-100.0 * math.log(ratio));
  }
}
