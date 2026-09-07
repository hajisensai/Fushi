import 'package:fushi/src/stats/interval_coverage.dart';

/// 阅读三域（EPUB / 漫画 / PDF）共用的**唯一**「读过」判据（用户 2026-09-06 两次裁定，
/// 决策与全口径对照见 `docs/plans/2026-09-06-read-unit-ledger.md`）：
///
/// > **入账额 = 本会话翻过的单元并集 ∩ [0, 当前位置)**。
///
/// 单元 = 半开区间 `[start, end)`：EPUB 是全书绝对字符偏移（分页 = 当前页可见区间、
/// 连续 = 一次停下时的可见区间、VN = 一屏），漫画 / PDF 是页号。**离开**一个单元那一刻
/// （翻到别的单元 / 跳走 / 关书）它并入「翻过的并集」；每次位置落定后按上式重算应入账
/// 集合，与已入账集合的差分交给回调：新增的子区间 → [onCredit]，不再满足的 → [onRetract]。
/// 并集只活在一个阅读器 State（会话）里，不持久化——关书重开再读同一页照常计。
///
/// 这条式子同时给出三种行为（都是纯函数级契约，见 `test/stats/read_unit_ledger_test.dart`）：
///  * **翻走即计**：顺序读时位置单调前进，翻走的页落进 `[0, 位置)` 即入账。没有停留门、
///    没有速率封顶：按住翻页键扫过去也算（第一次裁定）。
///  * **回翻撤回**：位置退到 X，X 之后已入账的部分撤回（误翻很多页再翻回来不算读过；
///    对齐 Hoshi 的会话级负数扣减，第二次裁定）。再前进 / 跳到 Y 时 `[X, Y)` 里此前翻过
///    的按并集恢复，不用重读；从未翻过的仍不计——跳转仍然「跳走前那页计、跳过的不计」。
///  * **会话内重读不双计**：并集去重，同一段内容至多入账一次。
///
/// 没有「播种 / 预置」API：跳转、换章、恢复都不需要告诉账本「这段跳过了」。此前 EPUB 的
/// 标量水位需要在恢复完成 / 进度条拖动 / 搜索跳转 / cue 跳转 / 字数补算五处播种，漏一处
/// 就是幻象字数（BUG-1107 / BUG-2206）；账本把这个类别的 bug 结构性消掉。
///
/// 其它契约：
///  * 同一页换了坐标（漫画单页↔双页 / spread↔webtoon）不是翻页：[rebaseOnNextArrive]
///    让下一次 [arrive] 只替换当前单元边界、不并入。EPUB 已不用它（BUG-2225）。
///  * 坐标系整体变更（章字数后台补算）：[reset] 清并集 + 丢当前；此前已入账的**沉没**
///    （不撤回——那是坐标精化，不是重读），之后按新坐标从零起。
///  * 停表期间的丢弃（BUG-2210）由 `StudyClock.addChars/addPages` 与 `retractChars/retractPages`
///    对称地保持，账本不管。
class ReadUnitLedger {
  ReadUnitLedger({required this.onCredit, required this.onRetract});

  /// 入账回调：本次新应入账的子区间（升序、不相交、非空）。消费方按域换算成字数 /
  /// 页数再 `StudyClock.addChars/addPages`。
  final void Function(List<(int, int)> fresh) onCredit;

  /// 撤回回调：本次不再应入账的子区间（升序、不相交、非空）。消费方按域换算后
  /// `StudyClock.retractChars/retractPages`。同一次落定里先撤回后入账。
  final void Function(List<(int, int)> retracted) onRetract;

  final IntervalCoverage _coverage = IntervalCoverage();
  IntervalCoverage _credited = IntervalCoverage();
  (int, int)? _current;
  bool _rebasePending = false;
  int? _position;

  /// 当前所在单元（诊断 / 测试）。
  (int, int)? get current => _current;

  /// 最近一次落定的位置（诊断 / 测试）：arrive 取单元起点，leave 取单元终点。
  int? get position => _position;

  /// 本会话翻过的单元并集（只读视图）。
  IntervalCoverage get coverage => _coverage;

  /// 当前已入账集合（只读视图）= [coverage] ∩ `[0, position)`。
  IntervalCoverage get credited => _credited;

  /// 当前已入账总长（字数 / 页数口径由消费方决定）。
  int get creditedLength => _credited.total;

  /// 位置落定在 `[start, end)`：与当前单元相同 → no-op；不同 → 当前单元并入并集
  /// （[rebaseOnNextArrive] 待生效时只切换不并入），再按新位置 [start] 重算入账。
  /// `end <= start` 一律忽略——JS 拿不到终点时宁可不计。
  void arrive(int start, int end) {
    if (end <= start) return;
    final (int, int)? cur = _current;
    if (cur != null && cur.$1 == start && cur.$2 == end) {
      _rebasePending = false;
      return;
    }
    if (cur != null && !_rebasePending) _coverage.add(cur.$1, cur.$2);
    _rebasePending = false;
    _current = (start, end);
    _reconcile(start);
  }

  /// 离开当前单元且不进入新单元（关书 / 跳走 / 显式跳句）：并入并集、按单元终点重算
  /// （你确实在这页）并清空当前。
  void leave() {
    final (int, int)? cur = _current;
    _current = null;
    _rebasePending = false;
    if (cur == null) return;
    _coverage.add(cur.$1, cur.$2);
    _reconcile(cur.$2);
  }

  /// 同一页即将换单元边界（漫画单页↔双页 / spread↔webtoon）：下一次 [arrive] 只替换
  /// 当前单元边界、不并入。没有当前单元时 no-op。
  void rebaseOnNextArrive() {
    if (_current != null) _rebasePending = true;
  }

  /// 丢弃当前单元、不并入、不重算（内容未就绪 / 兜底超时 / 导航失败）。
  void discard() {
    _current = null;
    _rebasePending = false;
  }

  /// 坐标系整体变更：清并集 + 丢当前；已入账的沉没（不撤回）。
  void reset() {
    _coverage.clear();
    _credited = IntervalCoverage();
    _position = null;
    discard();
  }

  void _reconcile(int position) {
    _position = position;
    final IntervalCoverage target = _coverage.clipBelow(position);
    final List<(int, int)> retracted = _credited.subtract(target);
    final List<(int, int)> fresh = target.subtract(_credited);
    _credited = target;
    if (retracted.isNotEmpty) onRetract(retracted);
    if (fresh.isNotEmpty) onCredit(fresh);
  }
}

/// [ReadUnitLedger.onCredit] / [ReadUnitLedger.onRetract] 的子区间总长度（字数 / 页数）。
int readUnitsLength(List<(int, int)> fresh) {
  int sum = 0;
  for (final (int s, int e) in fresh) {
    sum += e - s;
  }
  return sum;
}
