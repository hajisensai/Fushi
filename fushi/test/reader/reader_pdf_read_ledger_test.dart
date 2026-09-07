import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/read_unit_ledger.dart';

/// PDF 页数「读过」判据（2026-09-06 裁定，取代 BUG-2222 的标量水位
/// `pdfPagesNewlyReached`）：页面把每次 `_onPageChanged` 的页号交给 `ReadUnitLedger`
/// （单元 `[page, page+1)`），`onCredit` / `onRetract` 把页数 `addPages` / `retractPages`。
/// 这里用账本模拟 PDF 页面的接线，钉三条行为：顺翻每页翻走时计 1；回翻撤回落点
/// 之后已计的、再前翻按并集恢复；跳 N 页只计跳走前那页（跳过的从未成为当前单元）。
/// 页面接线本身由
/// `test/pages/reader_study_clock_gate_guard_static_test.dart` 源码守卫钉死。
void main() {
  late int pagesCredited;
  late ReadUnitLedger ledger;

  /// 与 `_ReaderPdfPageState._readLedger.onCredit` 同形。
  void onPageChanged(int pageIndex) => ledger.arrive(pageIndex, pageIndex + 1);

  setUp(() {
    pagesCredited = 0;
    ledger = ReadUnitLedger(
      onCredit: (List<(int, int)> fresh) =>
          pagesCredited += readUnitsLength(fresh),
      onRetract: (List<(int, int)> retracted) =>
          pagesCredited -= readUnitsLength(retracted),
    );
  });

  test('顺翻：每页在翻走时计 1，停在的当前页未翻走不计', () {
    onPageChanged(0);
    expect(pagesCredited, 0, reason: '到达首页不计');
    onPageChanged(1);
    expect(pagesCredited, 1);
    onPageChanged(2);
    expect(pagesCredited, 2);
    ledger.leave(); // 关书：结算停在的第 2 页
    expect(pagesCredited, 3);
  });

  test('回翻：撤回落点之后已计的页；再前翻按并集恢复；越过最远处的新页照常计', () {
    onPageChanged(0);
    onPageChanged(1);
    onPageChanged(2); // 已计 0、1
    onPageChanged(1); // 回翻：2 并入并集，位置 1 → 撤回 1
    expect(pagesCredited, 1);
    onPageChanged(0); // 位置 0 → 撤回 0
    expect(pagesCredited, 0);
    onPageChanged(1); // 恢复 0
    onPageChanged(2); // 恢复 1
    onPageChanged(3); // 恢复 2（并集里有，不用重读）
    expect(pagesCredited, 3);
    onPageChanged(4); // 离开 3：新页 → 1
    expect(pagesCredited, 4);
  });

  test('跳页：目录前跳 N 页只计跳走前那页，跳过的页不计（BUG-2222 的水位会计 N 页）', () {
    onPageChanged(0);
    onPageChanged(1); // 计 0
    onPageChanged(41); // 离开 1 → 计 1；2..40 从未成为当前单元
    expect(pagesCredited, 2);
    onPageChanged(42); // 计 41
    expect(pagesCredited, 3);
  });

  test('续读：恢复到存档页不预置，存档页是当前单元、翻走时计一次', () {
    onPageChanged(41); // 恢复落到存档页
    expect(pagesCredited, 0);
    onPageChanged(42);
    expect(pagesCredited, 1, reason: '存档页本会话翻走 → 计一次（与 Hoshi 同）');
  });

  test('同页重复回调（pdfrx 同页多次 onPageChanged）不计', () {
    onPageChanged(5);
    onPageChanged(5);
    onPageChanged(5);
    expect(pagesCredited, 0);
    onPageChanged(6);
    expect(pagesCredited, 1);
  });
}
