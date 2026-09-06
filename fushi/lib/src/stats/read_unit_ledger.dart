import 'package:fushi/src/stats/interval_coverage.dart';

/// 阅读三域（EPUB / 漫画 / PDF）共用的**唯一**「读过」判据：**翻走即计 + 会话覆盖
/// 并集去重**（用户 2026-09-06 裁定，对齐 Hoshi Reader；决策与全口径对照见
/// `docs/plans/2026-09-06-read-unit-ledger.md`）。
///
/// 单元 = 半开区间 `[start, end)`：EPUB 是全书绝对字符偏移（分页 = 当前页可见区间、
/// 连续 = 一次停下时的可见区间、VN = 一屏），漫画 / PDF 是页号。**离开**一个单元那一刻
/// （翻到别的单元 / 跳走 / 关书），把该单元里此前未覆盖的部分**全额**交给 [onCredit]；
/// 覆盖并集只活在一个阅读器 State（会话）里，不持久化——关书重开再读同一页照常计。
///
/// 设计要点（都是纯函数级契约，见 `test/stats/read_unit_ledger_test.dart`）：
///  * 没有停留门、没有速率封顶：按住翻页键扫过去也算（裁定）。
///  * 没有「播种 / 预置」API：跳转、换章、恢复都不需要告诉账本「这段跳过了」——只计
///    你翻走的单元，跳过的从未成为当前单元。此前 EPUB 的标量水位需要在恢复完成 /
///    进度条拖动 / 搜索跳转 / cue 跳转 / 字数补算五处播种，漏一处就是幻象字数
///    （BUG-1107 / BUG-2168）；账本把这个类别的 bug 结构性消掉。
///  * 会话内回翻 / 重读：并集已覆盖 → 0，不需要 Hoshi 的负数扣减。
///  * 同一页换了坐标（改字号 / 旋屏 / 分页↔连续）不是翻页：[rebaseOnNextArrive]
///    让下一次 [arrive] 只替换当前单元边界、不结算。
///  * 坐标系整体变更（章字数后台补算）：[reset] 清并集 + 丢当前，旧区间不再有意义。
///  * 停表期间的丢弃（BUG-2172）由 `StudyClock.addChars/addPages` 保持，账本不管。
class ReadUnitLedger {
  ReadUnitLedger({required this.onCredit, IntervalCoverage? coverage})
    : _coverage = coverage ?? IntervalCoverage();

  /// 结算回调：本次新覆盖的子区间（升序、不相交、非空）。消费方按域换算成字数 /
  /// 页数再 `StudyClock.addChars/addPages`。
  final void Function(List<(int, int)> fresh) onCredit;

  final IntervalCoverage _coverage;
  (int, int)? _current;
  bool _rebasePending = false;

  /// 当前所在单元（诊断 / 测试）。
  (int, int)? get current => _current;

  /// 本会话已覆盖并集（只读视图）。
  IntervalCoverage get coverage => _coverage;

  /// 位置落定在 `[start, end)`：与当前单元相同 → no-op；不同 → 先结算当前单元再切换
  /// （[rebaseOnNextArrive] 待生效时只切换不结算）。`end <= start` 一律忽略——JS 拿不到
  /// 终点时宁可不计。
  void arrive(int start, int end) {
    if (end <= start) return;
    final (int, int)? cur = _current;
    if (cur != null && cur.$1 == start && cur.$2 == end) {
      _rebasePending = false;
      return;
    }
    if (cur != null && !_rebasePending) _settle(cur);
    _rebasePending = false;
    _current = (start, end);
  }

  /// 离开当前单元且不进入新单元（关书 / dispose / 显式跳句）：结算并清空。
  void leave() {
    final (int, int)? cur = _current;
    _current = null;
    _rebasePending = false;
    if (cur != null) _settle(cur);
  }

  /// 同一页即将换坐标（重排 / 宽变 / 分页↔连续 / 界面缩放）：下一次 [arrive] 只替换
  /// 当前单元边界、不结算。没有当前单元时 no-op。
  void rebaseOnNextArrive() {
    if (_current != null) _rebasePending = true;
  }

  /// 丢弃当前单元、不结算（内容未就绪 / 兜底超时 / 导航失败）。
  void discard() {
    _current = null;
    _rebasePending = false;
  }

  /// 坐标系整体变更：清并集 + 丢当前。
  void reset() {
    _coverage.clear();
    discard();
  }

  void _settle((int, int) unit) {
    final List<(int, int)> fresh = _coverage.addFresh(unit.$1, unit.$2);
    if (fresh.isNotEmpty) onCredit(fresh);
  }
}

/// [ReadUnitLedger.onCredit] 的子区间总长度（字数 / 页数）。
int readUnitsLength(List<(int, int)> fresh) {
  int sum = 0;
  for (final (int s, int e) in fresh) {
    sum += e - s;
  }
  return sum;
}
