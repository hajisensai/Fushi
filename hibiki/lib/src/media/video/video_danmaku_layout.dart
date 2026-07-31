import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_danmaku_text_metrics.dart';

@immutable
class VideoDanmakuLayoutEntry {
  const VideoDanmakuLayoutEntry({
    required this.item,
    required this.lane,
    required this.position,
    required this.width,
    required this.opacity,
  });

  final VideoDanmakuItem item;
  final int lane;
  final Offset position;

  /// 文本实测渲染宽度（px）。滚动弹幕右边缘 = `position.dx + width`，是判断
  /// 「是否真的滑出视口」的唯一依据。
  final double width;

  final double opacity;
}

@immutable
class VideoDanmakuLayoutSnapshot {
  const VideoDanmakuLayoutSnapshot({
    required this.entries,
    required this.droppedForDensity,
  });

  final List<VideoDanmakuLayoutEntry> entries;
  final int droppedForDensity;
}

class VideoDanmakuLayout {
  VideoDanmakuLayout._();

  static VideoDanmakuLayoutSnapshot layout({
    required List<VideoDanmakuItem> items,
    required int positionMs,
    required Size viewportSize,
    required int maxActive,
    required int maxLanes,
    Duration scrollDuration = kDefaultVideoDanmakuScrollDuration,
    Duration fixedDuration = kDefaultVideoDanmakuFixedDuration,
    double fontScale = 1.0,
    double areaFraction = 1.0,
    VideoDanmakuTextMetrics? metrics,
  }) {
    final VideoDanmakuTextMetrics textMetrics =
        metrics ?? VideoDanmakuTextMetrics.shared;
    if (items.isEmpty ||
        viewportSize.width <= 0 ||
        viewportSize.height <= 0 ||
        maxActive <= 0 ||
        maxLanes <= 0) {
      return const VideoDanmakuLayoutSnapshot(
        entries: <VideoDanmakuLayoutEntry>[],
        droppedForDensity: 0,
      );
    }
    // [items] 契约按 startMs 升序（来源 video_danmaku_source.dart 解析后 sort）。
    // 活动窗口只可能落在 startMs ∈ [positionMs - maxDurationMs, positionMs]：
    //  - startMs > positionMs ⇒ elapsed<0（尚未出现）；
    //  - startMs < positionMs - maxDurationMs ⇒ 任何模式都 elapsed>durationMs（已过期）。
    // 用二分把每帧 O(N) 全量扫描收窄成只遍历该有序切片；切片内仍按各条自身
    // 模式的 durationMs 做精确判定，与原全量筛选逐条等价（fixed 模式窗口更短）。
    final int maxDurationMs = math.max(
      scrollDuration.inMilliseconds,
      fixedDuration.inMilliseconds,
    );
    final int loIndex = _lowerBoundByStartMs(items, positionMs - maxDurationMs);
    final int hiIndex = _lowerBoundByStartMs(items, positionMs + 1);
    final List<_ActiveItem> active = <_ActiveItem>[];
    for (int i = loIndex; i < hiIndex; i++) {
      final VideoDanmakuItem item = items[i];
      final int elapsed = positionMs - item.startMs;
      final int durationMs = item.mode == VideoDanmakuMode.scroll
          ? scrollDuration.inMilliseconds
          : fixedDuration.inMilliseconds;
      if (elapsed < 0 || elapsed > durationMs) continue;
      active.add(_ActiveItem(index: i, item: item, elapsedMs: elapsed));
    }
    if (active.isEmpty) {
      return const VideoDanmakuLayoutSnapshot(
        entries: <VideoDanmakuLayoutEntry>[],
        droppedForDensity: 0,
      );
    }
    active.sort((_ActiveItem a, _ActiveItem b) {
      final int byStart = a.item.startMs.compareTo(b.item.startMs);
      return byStart == 0 ? a.index.compareTo(b.index) : byStart;
    });
    final int allowed = normalizeVideoDanmakuMaxActive(maxActive);
    final List<_ActiveItem> capped =
        active.length <= allowed ? active : active.sublist(0, allowed);
    // TODO-1376：弹幕仅占画面顶部 [areaFraction] 高度带（默认满屏），把弹幕挤出底部
    // 字幕区；lane 高度随字号缩放 [fontScale] 放大，避免大字号相邻行重叠。
    final double band =
        viewportSize.height * areaFraction.clamp(0.0, 1.0).toDouble();
    final double laneHeight =
        math.max(18 * fontScale, band / math.max(1, maxLanes));
    final List<int> nextFreeMs = List<int>.filled(maxLanes, -1);
    final List<VideoDanmakuLayoutEntry> entries = <VideoDanmakuLayoutEntry>[];
    for (final _ActiveItem activeItem in capped) {
      final int lane = _pickLane(
        activeItem,
        nextFreeMs,
        maxLanes,
        scrollDuration.inMilliseconds,
      );
      final double top = (lane * laneHeight).clamp(
        0,
        math.max(0, band - laneHeight),
      );
      final double progress = _progressFor(
        activeItem,
        scrollDuration,
        fixedDuration,
      );
      // 实测渲染宽度（非估算）：滚动弹幕的行程是「视口宽 + 自身宽」，progress 走到
      // 1 的同一刻它离开活动集，所以宽度算少了就会在文本右半截还可见时被整条抹掉。
      final double width = textMetrics.widthOf(activeItem.item.text, fontScale);
      final double x = switch (activeItem.item.mode) {
        VideoDanmakuMode.scroll =>
          viewportSize.width - (viewportSize.width + width) * progress,
        VideoDanmakuMode.top => viewportSize.width * 0.5,
        VideoDanmakuMode.bottom => viewportSize.width * 0.5,
      };
      final double y = activeItem.item.mode == VideoDanmakuMode.bottom
          ? band - laneHeight - top
          : top;
      entries.add(VideoDanmakuLayoutEntry(
        item: activeItem.item,
        lane: lane,
        position: Offset(x, y),
        width: width,
        opacity: _opacityFor(activeItem.item.mode, progress),
      ));
      nextFreeMs[lane] = activeItem.item.startMs + 900;
    }
    return VideoDanmakuLayoutSnapshot(
      entries: entries,
      droppedForDensity: active.length - capped.length,
    );
  }

  static int _pickLane(
    _ActiveItem activeItem,
    List<int> nextFreeMs,
    int maxLanes,
    int scrollDurationMs,
  ) {
    final Iterable<int> laneOrder =
        activeItem.item.mode == VideoDanmakuMode.bottom
            ? Iterable<int>.generate(maxLanes, (int i) => maxLanes - 1 - i)
            : Iterable<int>.generate(maxLanes);
    for (final int lane in laneOrder) {
      if (activeItem.item.startMs >= nextFreeMs[lane]) return lane;
    }
    return activeItem.index % maxLanes;
  }

  static double _progressFor(
    _ActiveItem activeItem,
    Duration scrollDuration,
    Duration fixedDuration,
  ) {
    final int durationMs = activeItem.item.mode == VideoDanmakuMode.scroll
        ? scrollDuration.inMilliseconds
        : fixedDuration.inMilliseconds;
    return (activeItem.elapsedMs / durationMs).clamp(0.0, 1.0).toDouble();
  }

  /// 末段淡出**只属于固定弹幕**（top/bottom）：它们不移动，不淡出就是凭空消失。
  ///
  /// 滚动弹幕恒为不透明，靠位移一路滑到视口左侧之外、由 Stack 裁掉——这才是自然的
  /// 退场。旧实现对滚动弹幕也套同一条淡出曲线，而 `progress = 0.88` 时短弹幕往往
  /// 还在画面里（`x = 视口宽 - (视口宽 + 文本宽) * 0.88`），于是它在屏幕中间就渐隐没了。
  static double _opacityFor(VideoDanmakuMode mode, double progress) {
    if (mode == VideoDanmakuMode.scroll) return 1;
    if (progress < 0.88) return 1;
    return ((1 - progress) / 0.12).clamp(0.0, 1.0).toDouble();
  }

  /// 二分（lowerBound）：在按 startMs 升序的 [items] 中返回第一个
  /// `startMs >= target` 的下标；不存在则返回 `items.length`。
  /// O(log N) 定位活动窗口起止，替代每帧 O(N) 全量扫描。
  static int _lowerBoundByStartMs(List<VideoDanmakuItem> items, int target) {
    int lo = 0;
    int hi = items.length;
    while (lo < hi) {
      final int mid = lo + ((hi - lo) >> 1);
      if (items[mid].startMs < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

class _ActiveItem {
  const _ActiveItem({
    required this.index,
    required this.item,
    required this.elapsedMs,
  });

  final int index;
  final VideoDanmakuItem item;
  final int elapsedMs;
}
