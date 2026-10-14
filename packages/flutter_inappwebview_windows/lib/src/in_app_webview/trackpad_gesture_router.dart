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
/// 即判为捏合，此后到手势结束只发缩放、不发平移。
///
/// 反馈 SUsLYAlCJF（查词弹窗用触控板几乎滑不动、慢滑完全不动）：引擎报的 `scale`
/// 是**自手势开始的累计值**，两指慢慢滑一段长距离时两指间距会缓慢漂移，累计 3%
/// 只要零点几毫米。旧判据在手势的**任何时刻**越过阈值都改判捏合，于是一次本来
/// 明明是滚动的慢滑中途被锁成捏合——此后平移全部丢弃（只剩 Ctrl+滚轮，弹窗
/// popup.js 对它直接 return），表现就是「滑不动」。分类必须在手势开头一次定死：
/// 平移先走过 [scrollLockPanDistance] 而缩放仍在阈值内 = 本次手势是滚动，之后
/// 缩放怎么漂都不再改判；缩放先越过阈值 = 捏合（BUG-2758 的起手照旧不丢）。
class TrackpadGestureRouter {
  /// 两指滚动时 DirectManipulation 报的 scale 恒在 1 附近，捏合一开始就
  /// 明显偏离；3% 足以滤掉滚动抖动，又不至于吃掉捏合的起手。
  static const double pinchScaleThreshold = 0.03;

  /// 尚未分类时，平移累计走过这么多逻辑像素（缩放仍在阈值内）就锁定为滚动。
  /// 捏合时指尖中点基本不动，起手阶段平移远到不了这个量，缩放早已越过阈值。
  static const double scrollLockPanDistance = 8.0;

  _TrackpadGesturePhase _phase = _TrackpadGesturePhase.undecided;
  Offset _undecidedPan = Offset.zero;
  double _pinchBaseScale = 1.0;

  bool get isPinching => _phase == _TrackpadGesturePhase.pinch;

  /// PointerPanZoomStart：新手势从未分类状态开始。
  void start() {
    _phase = _TrackpadGesturePhase.undecided;
    _undecidedPan = Offset.zero;
    _pinchBaseScale = 1.0;
  }

  /// PointerPanZoomUpdate。[scale] 是自手势开始的累计缩放。
  TrackpadGestureOutput update({
    required Offset panDelta,
    required double scale,
  }) {
    if (_phase == _TrackpadGesturePhase.undecided) _classify(panDelta, scale);
    if (_phase != _TrackpadGesturePhase.pinch) {
      return TrackpadGestureOutput.scroll(panDelta);
    }
    // 基准在判定前恒为 1，越过阈值那一下把已攒的缩放一次交出去，起手不丢。
    final double ratio = scale / _pinchBaseScale;
    _pinchBaseScale = scale;
    if (!(ratio > 0) || !ratio.isFinite) {
      return const TrackpadGestureOutput.pinch(0);
    }
    return TrackpadGestureOutput.pinch(-100.0 * math.log(ratio));
  }

  void _classify(Offset panDelta, double scale) {
    if ((scale - 1.0).abs() >= pinchScaleThreshold) {
      _phase = _TrackpadGesturePhase.pinch;
      return;
    }
    _undecidedPan += panDelta;
    if (_undecidedPan.distance >= scrollLockPanDistance) {
      _phase = _TrackpadGesturePhase.scroll;
    }
  }
}

enum _TrackpadGesturePhase { undecided, scroll, pinch }
