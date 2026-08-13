import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/video/video_danmaku_model.dart';

/// 某一行上「最后一条弹幕」的占用信息——判断新弹幕能否安全进同一行的全部依据。
@immutable
class _RowOccupant {
  const _RowOccupant({
    required this.startMs,
    required this.width,
    required this.scroll,
    required this.durationMs,
  });

  final int startMs;
  final double width;
  final bool scroll;
  final int durationMs;
}

/// 弹幕行分配板：**行号是弹幕自身的属性，出生那一刻定下、终身不变**。
///
/// 旧实现每帧拿「当前活动集」从零跑一遍贪心分配，于是任何一条弹幕过期离开活动集，
/// 排在它后面的弹幕全部重新分配行号——整屏弹幕跟着换行，观感就是「谁一消失，剩下的
/// 就抖一下」。把行号变成弹幕自己的属性之后，一条弹幕的整个生命周期只发生两件事：
/// 出生时挑一行，然后一路滑出视口。中途没有任何外力能改变它的位置或可见性，于是
/// 「消失」永远只剩一种原因——它自己走出去了。
///
/// 密度上限同样在出生那一刻裁决：当时挤不下就永久不出现（[rowFor] 返回 null），
/// 而不是等前面的弹幕过期后再凭空冒到画面中间。
class VideoDanmakuLaneBoard {
  VideoDanmakuLaneBoard();

  /// 每行最后一条弹幕的占用；null = 该行从未用过。
  List<_RowOccupant?> _rows = <_RowOccupant?>[];

  /// 弹幕在 items 列表中的下标 -> 已分配行号。key 用下标而非 item 实例，是因为
  /// items 列表本身就是 identity 真相源（换列表即整板重置），下标还能按活动窗口
  /// 下界批量遗忘。
  final Map<int, int> _rowByIndex = <int, int>{};

  /// 出生时被密度上限挡下的下标：记住它，免得下一帧又把它当新弹幕重新裁决一次。
  final Set<int> _rejected = <int>{};

  Object? _itemsToken;
  double _viewportWidth = 0;
  int _maxRows = 0;
  int _maxActive = 0;
  int _scrollDurationMs = 0;
  int _fixedDurationMs = 0;
  double _fontScale = 1;
  int _lastPositionMs = 0;
  bool _primed = false;

  /// 每帧开头调用。任一几何 / 来源 / 时间轴前提变化都整板重置。
  ///
  /// 重置本身会造成一次重排，但那是「换视频、改设置、seek」的必然结果，与「弹幕
  /// 自然退场」无关——本类要消灭的正是后者引发的重排。
  void beginFrame({
    required Object itemsToken,
    required double viewportWidth,
    required int maxRows,
    required int maxActive,
    required int scrollDurationMs,
    required int fixedDurationMs,
    required double fontScale,
    required int positionMs,
  }) {
    final int maxDurationMs = math.max(scrollDurationMs, fixedDurationMs);
    final bool timelineJumped = !_primed ||
        positionMs < _lastPositionMs ||
        positionMs - _lastPositionMs > maxDurationMs;
    final bool premiseChanged = !identical(itemsToken, _itemsToken) ||
        viewportWidth != _viewportWidth ||
        maxRows != _maxRows ||
        maxActive != _maxActive ||
        scrollDurationMs != _scrollDurationMs ||
        fixedDurationMs != _fixedDurationMs ||
        fontScale != _fontScale;
    if (timelineJumped || premiseChanged) {
      _itemsToken = itemsToken;
      _viewportWidth = viewportWidth;
      _maxRows = maxRows;
      _maxActive = maxActive;
      _scrollDurationMs = scrollDurationMs;
      _fixedDurationMs = fixedDurationMs;
      _fontScale = fontScale;
      _rows = List<_RowOccupant?>.filled(maxRows, null);
      _rowByIndex.clear();
      _rejected.clear();
      _primed = true;
    }
    _lastPositionMs = positionMs;
  }

  /// 丢弃 [firstActiveIndex] 之前的记忆：那些弹幕已经永久离场，不会再被问到。
  void forgetBefore(int firstActiveIndex) {
    if (_rowByIndex.isNotEmpty) {
      _rowByIndex.removeWhere((int index, int _) => index < firstActiveIndex);
    }
    if (_rejected.isNotEmpty) {
      _rejected.removeWhere((int index) => index < firstActiveIndex);
    }
  }

  /// 下标 [index] 这条弹幕占的行号；null = 它在出生那一刻就被密度上限挡下，本次
  /// 播放不会出现。
  ///
  /// [width] 是弹幕的**占地宽**（文本框 + 两侧阴影），与位移几何用的是同一个尺寸——
  /// 两边不一致，算出来的「这行空了」就会比实际早，前后两条叠边。
  ///
  /// [admitNewborn] 为 false 表示本帧已经排满，只有已经在场的弹幕才继续渲染。
  int? rowFor({
    required int index,
    required VideoDanmakuItem item,
    required double width,
    required bool admitNewborn,
  }) {
    final int? assigned = _rowByIndex[index];
    if (assigned != null) return assigned;
    if (_rejected.contains(index)) return null;
    if (!admitNewborn || _maxRows <= 0) {
      _rejected.add(index);
      return null;
    }
    final int row = _pickRow(item, width);
    _rowByIndex[index] = row;
    _rows[row] = _RowOccupant(
      startMs: item.startMs,
      width: width,
      scroll: item.mode == VideoDanmakuMode.scroll,
      durationMs: item.mode == VideoDanmakuMode.scroll
          ? _scrollDurationMs
          : _fixedDurationMs,
    );
    return row;
  }

  /// 底部弹幕从最后一行往上找，其余从第一行往下找；都排不下时退让给「最早空出」
  /// 的那一行——确定性的兜底，不会像取模那样每帧在两个分支之间跳。
  int _pickRow(VideoDanmakuItem item, double width) {
    final bool fromBottom = item.mode == VideoDanmakuMode.bottom;
    int fallbackRow = fromBottom ? _maxRows - 1 : 0;
    double fallbackFreeAtMs = double.infinity;
    for (int i = 0; i < _maxRows; i++) {
      final int row = fromBottom ? _maxRows - 1 - i : i;
      final _RowOccupant? occupant = _rows[row];
      if (occupant == null) return row;
      final double freeAtMs = _freeAtMsFor(occupant, item, width);
      if (item.startMs >= freeAtMs) return row;
      if (freeAtMs < fallbackFreeAtMs) {
        fallbackFreeAtMs = freeAtMs;
        fallbackRow = row;
      }
    }
    return fallbackRow;
  }

  /// 该行能接纳下一条弹幕的最早时刻（ms）。
  ///
  /// 两条都是滚动弹幕时是纯几何：同一时长下行程 = 视口宽 + 自身宽，所以**越宽越快**。
  /// 令 `f(w) = D * w / (视口宽 + w)`：
  ///   - `f(前一条宽)` = 前一条尾巴完全进屏所需的时间（不等就是头尾叠在一起）；
  ///   - `f(本条宽)`   = 本条更快时不追上前一条尾巴所需的最小间隔。
  /// 两个约束都是时间的线性函数，取端点即可；而 f 单调递增，于是两者合并成对
  /// `max(两条宽)` 求一次 f——没有分支，也不需要「够不够 900ms」这种拍脑袋常数。
  ///
  /// 只要有一方是固定弹幕（top/bottom），它整行占满、不移动，只能等它自己离场。
  double _freeAtMsFor(
    _RowOccupant occupant,
    VideoDanmakuItem item,
    double width,
  ) {
    if (!occupant.scroll || item.mode != VideoDanmakuMode.scroll) {
      return (occupant.startMs + occupant.durationMs).toDouble();
    }
    final double wide = math.max(occupant.width, width);
    return occupant.startMs +
        _scrollDurationMs * wide / (_viewportWidth + wide);
  }
}
