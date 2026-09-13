import 'dart:convert';

/// 整数半开区间 `[start, end)` 的**并集**：有序、两两不相交、相邻已合并。
///
/// 统计域「首次覆盖」去重的唯一数据结构（2026-09-06 从视频专用的 `WatchCoverage`
/// 抽成通用类型）：
///  * 视频：片内毫秒区间——只计首次覆盖的观看时长（BUG-2108，`VideoWatchTracker`）。
///  * 阅读三域（EPUB / 漫画 / PDF）：EPUB 全书绝对字符偏移、漫画 / PDF 页号——
///    `ReadUnitLedger` 翻走即计时按并集去重（会话内回翻 / 重读不计）。
///
/// 用区间并集而不是「最远到过的位置」标量：标量 high-water 在用户先跳到末尾看一眼、
/// 再回头从中间读时会把整段真实首读压成 0（部分观测 + 标量水位 = 静默永久压制）。
/// 区间并集对任意顺序都正确，没有特殊情况。
///
/// 序列化为 JSON `[[start,end],...]`（视频按 `videoWatchCoveragePrefKey` 存偏好表）；
/// 解析容错：非法输入当空。
class IntervalCoverage {
  IntervalCoverage([Iterable<(int, int)> ranges = const <(int, int)>[]]) {
    for (final (int start, int end) in ranges) {
      add(start, end);
    }
  }

  /// 解析 [toJson] 的输出；null / 非法 / 非数组一律当空覆盖（宁可重算首次，不炸）。
  factory IntervalCoverage.fromJson(String? json) {
    if (json == null || json.isEmpty) return IntervalCoverage();
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return IntervalCoverage();
    }
    if (decoded is! List) return IntervalCoverage();
    final IntervalCoverage out = IntervalCoverage();
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

  /// 已覆盖总长度（视频 = 毫秒，阅读 = 字符 / 页）。
  int get total {
    int sum = 0;
    for (final (int start, int end) in _ranges) {
      sum += end - start;
    }
    return sum;
  }

  /// 并入 `[start, end)`，返回**此前未覆盖**的长度（= 本次真正新到的内容量）。
  /// 空 / 倒序区间返回 0 且不改状态。
  int add(int start, int end) {
    int fresh = 0;
    for (final (int s, int e) in addFresh(start, end)) {
      fresh += e - s;
    }
    return fresh;
  }

  /// 并入 `[start, end)`，返回**此前未覆盖的子区间**（升序、不相交）。空 / 倒序区间
  /// 返回空表且不改状态。漫画按页号取每页字数、诊断「这次到底新读了哪几段」都要
  /// 子区间而不只是总量。
  List<(int, int)> addFresh(int start, int end) {
    if (end <= start) return const <(int, int)>[];
    final List<(int, int)> fresh = <(int, int)>[];
    int cursor = start;
    for (final (int s, int e) in _ranges) {
      if (e <= cursor) continue;
      if (s >= end) break;
      if (s > cursor) fresh.add((cursor, s));
      if (e > cursor) cursor = e;
    }
    if (cursor < end) fresh.add((cursor, end));

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
    return fresh;
  }

  /// `[start, end)` 中已被覆盖的长度。
  int covered(int start, int end) {
    if (end <= start) return 0;
    int sum = 0;
    for (final (int s, int e) in _ranges) {
      if (e <= start) continue;
      if (s >= end) break;
      final int lo = s > start ? s : start;
      final int hi = e < end ? e : end;
      if (hi > lo) sum += hi - lo;
    }
    return sum;
  }

  /// `[start, end)` 是否已整段覆盖（空区间视为已覆盖）。
  bool covers(int start, int end) =>
      end <= start || covered(start, end) == end - start;

  /// 与 `(-∞, position)` 的交集（新对象）：`ReadUnitLedger` 用它取「当前位置之前
  /// 翻过的部分」作为应入账集合。
  IntervalCoverage clipBelow(int position) {
    final IntervalCoverage out = IntervalCoverage();
    for (final (int s, int e) in _ranges) {
      if (s >= position) break;
      out._ranges.add((s, e < position ? e : position));
    }
    return out;
  }

  /// 本并集减去 [other]：属于本并集、不属于 [other] 的子区间（升序、不相交）。
  /// `ReadUnitLedger` 拿它算「应入账 − 已入账」（新增）与「已入账 − 应入账」（撤回）。
  List<(int, int)> subtract(IntervalCoverage other) {
    final List<(int, int)> out = <(int, int)>[];
    final List<(int, int)> cut = other._ranges;
    int j = 0;
    for (final (int s, int e) in _ranges) {
      int cursor = s;
      while (j < cut.length && cut[j].$2 <= cursor) {
        j++;
      }
      int k = j;
      while (k < cut.length && cut[k].$1 < e) {
        final (int cs, int ce) = cut[k];
        if (cs > cursor) out.add((cursor, cs));
        if (ce > cursor) cursor = ce;
        k++;
      }
      if (cursor < e) out.add((cursor, e));
    }
    return out;
  }

  /// 清空（坐标系整体变更时用，`ReadUnitLedger.reset`）。
  void clear() => _ranges.clear();

  /// 深拷贝（视频 tracker 在 attach 时留一份「本次会话前」快照给字幕字数门用）。
  IntervalCoverage copy() => IntervalCoverage(_ranges);

  String toJson() => jsonEncode(<List<int>>[
    for (final (int s, int e) in _ranges) <int>[s, e],
  ]);
}
