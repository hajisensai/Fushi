import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/video/video_danmaku_lane_board.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/media/video/video_danmaku_text_metrics.dart';

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

  /// 行号（0 = 最上面一行）。滚动/顶部弹幕从 0 往下挑，底部弹幕从最后一行往上挑，
  /// 但三种模式共用同一套行号与同一块占用板，所以模式混排也不会撞在一起。
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

/// 弹幕逐帧布局器。
///
/// **有状态，必须按播放会话长期持有**（[VideoDanmakuOverlay] 里就是一个 final 字段）：
/// 行号分配记在 [VideoDanmakuLaneBoard] 里跨帧延续，这正是「某条弹幕退场时其余弹幕
/// 不重排」的前提。每帧新建一个实例等于丢掉这份记忆，重排会立刻回来。
class VideoDanmakuLayout {
  VideoDanmakuLayout();

  final VideoDanmakuLaneBoard _board = VideoDanmakuLaneBoard();

  VideoDanmakuLayoutSnapshot layout({
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
    // TODO-1376：弹幕仅占画面顶部 [areaFraction] 高度带（默认满屏），把弹幕挤出底部
    // 字幕区；行高不得低于实测单行文本高度，否则相邻行直接糊在一起。
    final double band =
        viewportSize.height * areaFraction.clamp(0.0, 1.0).toDouble();
    final double minLaneHeight = textMetrics.lineHeight(fontScale);
    final double evenLaneHeight = band / maxLanes;
    final double laneHeight = math.max(minLaneHeight, evenLaneHeight);
    // 放得下几行就只发几行的号——靠 clamp 把越界行压回带内，等于让多个行号落在
    // 同一个 y 上互相覆盖，那是伪装成「有 maxLanes 行」的重叠。
    final int rows = evenLaneHeight >= minLaneHeight
        ? maxLanes
        : math.max(1, math.min(maxLanes, band ~/ minLaneHeight));
    final int allowed = normalizeVideoDanmakuMaxActive(maxActive);
    _board.beginFrame(
      itemsToken: items,
      viewportWidth: viewportSize.width,
      maxRows: rows,
      maxActive: allowed,
      scrollDurationMs: scrollDuration.inMilliseconds,
      fixedDurationMs: fixedDuration.inMilliseconds,
      fontScale: fontScale,
      positionMs: positionMs,
    );
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
    _board.forgetBefore(loIndex);
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
    final List<VideoDanmakuLayoutEntry> entries = <VideoDanmakuLayoutEntry>[];
    for (final _ActiveItem activeItem in active) {
      // 实测渲染宽度（非估算）：progress 走到 1 的同一刻弹幕离开活动集，宽度算少了
      // 就会在文本右半截还可见时被整条抹掉。
      final double width = textMetrics.widthOf(activeItem.item.text, fontScale);
      // 弹幕真正占的地盘是「文本框 + 两侧阴影」。位移几何与行占用都按这个实际尺寸
      // 算，退场才发生在屏幕之外（否则文本框刚压线出屏时，屏幕左缘还挂着一道阴影
      // 残影跟着被抹掉），同一行的前后两条也才真的不叠边。
      final double occupiedWidth = width + 2 * kVideoDanmakuShadowOverflow;
      // 行号在出生那一刻定死并终身不变；密度上限同样在出生那一刻裁决。已经在场的
      // 弹幕永远续渲染，所以任何一条退场都不会牵动其余弹幕的位置或可见性。
      final int? row = _board.rowFor(
        index: activeItem.index,
        item: activeItem.item,
        width: occupiedWidth,
        admitNewborn: entries.length < allowed,
      );
      if (row == null) continue;
      final double progress = _progressFor(
        activeItem,
        scrollDuration,
        fixedDuration,
      );
      // 滚动行程 = 视口宽 + 占地宽；`+ kVideoDanmakuShadowOverflow` 把坐标从「阴影框
      // 左边缘」换算回「文本框左边缘」。progress=1 时文本右边缘停在 -阴影溢出 处，
      // 连同阴影一起走完全屏，下一帧离开活动集才不会在画面里被抹掉。
      final double x = switch (activeItem.item.mode) {
        VideoDanmakuMode.scroll => viewportSize.width -
            (viewportSize.width + occupiedWidth) * progress +
            kVideoDanmakuShadowOverflow,
        VideoDanmakuMode.top => viewportSize.width * 0.5,
        VideoDanmakuMode.bottom => viewportSize.width * 0.5,
      };
      entries.add(VideoDanmakuLayoutEntry(
        item: activeItem.item,
        lane: row,
        position: Offset(x, row * laneHeight),
        width: width,
        opacity: _opacityFor(activeItem.item.mode, progress),
      ));
    }
    return VideoDanmakuLayoutSnapshot(
      entries: entries,
      droppedForDensity: active.length - entries.length,
    );
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
