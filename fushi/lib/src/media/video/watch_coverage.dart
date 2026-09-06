import 'dart:convert';

/// 一部视频**已看过的片内区间并集**（毫秒，半开区间 `[start, end)`），有序、两两不
/// 相交、相邻已合并。
///
/// 观看时长口径（用户拍板 2026-09-04，BUG-2108）：**只计首次覆盖**——回放上一句、
/// 拖回重听、次日重看，位置推进到的片内区间若已在并集里就不计时。因此单部视频
/// 累计观看时长天然 ≤ 片长，与「一集 24 分钟却记了 59 分钟」的直觉对齐。
///
/// 用区间并集而不是「最远看到的位置」标量：标量 high-water 在用户先跳到片尾看一眼、
/// 再回头从中间看时会把整段真实首看压成 0（部分观测 + 标量水位 = 静默永久压制）。
/// 区间并集对任意观看顺序都正确，没有特殊情况。
///
/// 序列化为 JSON `[[start,end],...]` 存偏好表（键见 fushi_core 的
/// `videoWatchCoveragePrefKey`）；解析容错：非法输入当空。
class WatchCoverage {
  WatchCoverage([Iterable<(int, int)> ranges = const <(int, int)>[]]) {
    for (final (int start, int end) in ranges) {
      add(start, end);
    }
  }

  /// 解析 [toJson] 的输出；null / 非法 / 非数组一律当空覆盖（宁可重算首看，不炸）。
  factory WatchCoverage.fromJson(String? json) {
    if (json == null || json.isEmpty) return WatchCoverage();
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return WatchCoverage();
    }
    if (decoded is! List) return WatchCoverage();
    final WatchCoverage out = WatchCoverage();
    for (final Object? item in decoded) {
      if (item is! List || item.length != 2) continue;
      final Object? a = item[0];
      final Object? b = item[1];
      if (a is! num || b is! num) continue;
      out.add(a.toInt(), b.toInt());
    }
    return out;
  }

  final List<(int, int)> _ranges = <(int, int)>[];

  /// 只读视图（测试 / 诊断）。
  List<(int, int)> get ranges => List<(int, int)>.unmodifiable(_ranges);

  bool get isEmpty => _ranges.isEmpty;

  /// 已覆盖总毫秒数。
  int get totalMs {
    int total = 0;
    for (final (int start, int end) in _ranges) {
      total += end - start;
    }
    return total;
  }

  /// 并入 `[start, end)`，返回**此前未覆盖**的毫秒数（= 本次真正新看到的内容长度）。
  /// 空 / 倒序区间返回 0 且不改状态。
  int add(int start, int end) {
    if (end <= start) return 0;
    final int before = coveredMs(start, end);
    int newStart = start;
    int newEnd = end;
    int insertAt = _ranges.length;
    final List<(int, int)> kept = <(int, int)>[];
    bool placed = false;
    for (final (int s, int e) in _ranges) {
      if (e < newStart) {
        // 完全在左侧（含相邻 e == newStart 会合并，故用 <）。
        kept.add((s, e));
        continue;
      }
      if (s > newEnd) {
        // 完全在右侧：新区间先落位，之后照抄。
        if (!placed) {
          insertAt = kept.length;
          placed = true;
        }
        kept.add((s, e));
        continue;
      }
      // 相交或相邻：吸收进新区间。
      if (s < newStart) newStart = s;
      if (e > newEnd) newEnd = e;
    }
    if (!placed) insertAt = kept.length;
    kept.insert(insertAt, (newStart, newEnd));
    _ranges
      ..clear()
      ..addAll(kept);
    return (end - start) - before;
  }

  /// `[start, end)` 中已被覆盖的毫秒数。
  int coveredMs(int start, int end) {
    if (end <= start) return 0;
    int covered = 0;
    for (final (int s, int e) in _ranges) {
      if (e <= start) continue;
      if (s >= end) break;
      final int lo = s > start ? s : start;
      final int hi = e < end ? e : end;
      if (hi > lo) covered += hi - lo;
    }
    return covered;
  }

  /// `[start, end)` 是否已整段覆盖（空区间视为已覆盖）。
  bool covers(int start, int end) =>
      end <= start || coveredMs(start, end) == end - start;

  /// 深拷贝（tracker 在 attach 时留一份「本次会话前」快照给字幕字数门用）。
  WatchCoverage copy() => WatchCoverage(_ranges);

  String toJson() => jsonEncode(<List<int>>[
    for (final (int s, int e) in _ranges) <int>[s, e],
  ]);
}
