import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'package:hibiki/src/media/video/video_danmaku_model.dart';

@immutable
class VideoDanmakuLayoutEntry {
  const VideoDanmakuLayoutEntry({
    required this.item,
    required this.lane,
    required this.position,
    required this.opacity,
  });

  final VideoDanmakuItem item;
  final int lane;
  final Offset position;
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
  }) {
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
    final List<_ActiveItem> active = <_ActiveItem>[];
    for (int i = 0; i < items.length; i++) {
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
    final double laneHeight =
        math.max(18, viewportSize.height / math.max(1, maxLanes));
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
        math.max(0, viewportSize.height - laneHeight),
      );
      final double progress = _progressFor(
        activeItem,
        scrollDuration,
        fixedDuration,
      );
      final double x = switch (activeItem.item.mode) {
        VideoDanmakuMode.scroll => viewportSize.width -
            (viewportSize.width + _estimatedWidth(activeItem.item.text)) *
                progress,
        VideoDanmakuMode.top => viewportSize.width * 0.5,
        VideoDanmakuMode.bottom => viewportSize.width * 0.5,
      };
      final double y = activeItem.item.mode == VideoDanmakuMode.bottom
          ? viewportSize.height - laneHeight - top
          : top;
      entries.add(VideoDanmakuLayoutEntry(
        item: activeItem.item,
        lane: lane,
        position: Offset(x, y),
        opacity: _opacityFor(progress),
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

  static double _opacityFor(double progress) {
    if (progress < 0.88) return 1;
    return ((1 - progress) / 0.12).clamp(0.0, 1.0).toDouble();
  }

  static double _estimatedWidth(String text) =>
      (text.runes.length * 18.0).clamp(36.0, 420.0).toDouble();
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
