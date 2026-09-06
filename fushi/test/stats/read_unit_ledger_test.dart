import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/interval_coverage.dart';
import 'package:fushi/src/stats/read_unit_ledger.dart';

/// 「翻走即计 + 会话覆盖并集」的行为契约（用户 2026-09-06 裁定，对齐 Hoshi）。
/// 每条对应 `docs/plans/2026-09-06-read-unit-ledger.md` 边界表的一行。
void main() {
  late List<List<(int, int)>> credits;
  late ReadUnitLedger ledger;

  setUp(() {
    credits = <List<(int, int)>>[];
    ledger = ReadUnitLedger(onCredit: credits.add);
  });

  int total() => credits.fold<int>(
    0,
    (int a, List<(int, int)> f) => a + readUnitsLength(f),
  );

  test('A→B→C 快速连翻：每页在翻走时全额计入，当前页未翻走不计', () {
    ledger.arrive(0, 500);
    expect(credits, isEmpty, reason: '到达不计');
    ledger.arrive(500, 1000);
    expect(credits, <List<(int, int)>>[
      <(int, int)>[(0, 500)],
    ]);
    ledger.arrive(1000, 1500);
    expect(total(), 1000);
    expect(ledger.current, (1000, 1500));
  });

  test('回翻到已计过的页：翻走时计 0；再前翻已覆盖也是 0；越过最远处才计', () {
    ledger
      ..arrive(0, 500)
      ..arrive(500, 1000)
      ..arrive(1000, 1500); // 已计 0..1000
    ledger.arrive(500, 1000); // 回翻：结算 1000..1500
    expect(total(), 1500);
    ledger.arrive(0, 500); // 结算 500..1000：已覆盖 → 无回调
    expect(credits.length, 3);
    ledger.arrive(1000, 1500); // 结算 0..500：已覆盖
    ledger.arrive(1500, 2000); // 结算 1000..1500：已覆盖
    expect(total(), 1500);
    ledger.arrive(2000, 2500); // 结算 1500..2000：新页
    expect(total(), 2000);
  });

  test('同单元重复 arrive（同页多次采样）不结算、不改当前', () {
    ledger.arrive(0, 500);
    ledger.arrive(0, 500);
    ledger.arrive(0, 500);
    expect(credits, isEmpty);
    expect(ledger.current, (0, 500));
  });

  test('连续模式部分重叠：只计新露出的部分，且回调给出精确子区间', () {
    ledger.arrive(0, 800);
    ledger.arrive(300, 1100); // 结算 0..800
    ledger.arrive(600, 1400); // 结算 300..1100：只有 800..1100 是新的
    expect(credits, <List<(int, int)>>[
      <(int, int)>[(0, 800)],
      <(int, int)>[(800, 1100)],
    ]);
    expect(ledger.coverage.ranges, <(int, int)>[(0, 1100)]);
  });

  test('leave：结算当前并清空（关书 / 显式跳句）', () {
    ledger.arrive(0, 500);
    ledger.leave();
    expect(total(), 500);
    expect(ledger.current, isNull);
    ledger.leave();
    expect(credits.length, 1, reason: '重复 leave 幂等');
  });

  test('跳转：跳走前那页计入，跳过的从未成为当前单元所以不计，落点页翻走时计', () {
    ledger.arrive(0, 500);
    ledger.arrive(5000, 5500); // 目录跳转落点：结算 0..500
    expect(total(), 500);
    ledger.arrive(5500, 6000); // 结算 5000..5500
    expect(total(), 1000);
    expect(ledger.coverage.covers(500, 5000), isFalse, reason: '跳过的段落不算读过');
  });

  test('rebaseOnNextArrive：同页换坐标不结算，以新边界为当前；之后翻走按新边界计', () {
    ledger.arrive(1000, 1500);
    ledger.rebaseOnNextArrive();
    ledger.arrive(1000, 1650); // 缩字号：同页多露出 150 字
    expect(credits, isEmpty);
    expect(ledger.current, (1000, 1650));
    ledger.arrive(1650, 2300);
    expect(credits, <List<(int, int)>>[
      <(int, int)>[(1000, 1650)],
    ]);
  });

  test('rebase 待生效时同单元 arrive 清旗；无当前单元时 rebase 是 no-op', () {
    ledger.rebaseOnNextArrive();
    ledger.arrive(0, 500);
    ledger.arrive(500, 1000);
    expect(total(), 500, reason: '开书前的 rebase 不影响首页结算');
    ledger.rebaseOnNextArrive();
    ledger.arrive(500, 1000); // 同单元：清旗
    ledger.arrive(1000, 1500); // 正常结算 500..1000
    expect(total(), 1000);
  });

  test('discard：丢弃当前不结算；reset：清并集后旧区间可再计', () {
    ledger.arrive(0, 500);
    ledger.discard();
    expect(credits, isEmpty);
    expect(ledger.current, isNull);
    ledger
      ..arrive(0, 500)
      ..arrive(500, 1000);
    expect(total(), 500);
    ledger.reset();
    expect(ledger.coverage.isEmpty, isTrue);
    expect(ledger.current, isNull);
    ledger
      ..arrive(0, 500)
      ..arrive(500, 1000);
    expect(total(), 1000, reason: '坐标系变了，旧覆盖作废');
  });

  test('end <= start 忽略（JS 拿不到终点宁可不计）', () {
    ledger.arrive(500, 500);
    ledger.arrive(500, 100);
    ledger.arrive(500, -1);
    expect(ledger.current, isNull);
    ledger.arrive(0, 500);
    ledger.arrive(700, 400); // 非法：不结算、不切换
    expect(credits, isEmpty);
    expect(ledger.current, (0, 500));
  });

  test('外部注入并集：会话前已覆盖的段不计（供需要持久化的域复用）', () {
    final IntervalCoverage seed = IntervalCoverage(<(int, int)>[(0, 1000)]);
    final ReadUnitLedger l = ReadUnitLedger(
      onCredit: credits.add,
      coverage: seed,
    );
    l
      ..arrive(0, 500)
      ..arrive(500, 1000)
      ..arrive(1000, 1500)
      ..arrive(1500, 2000);
    expect(credits, <List<(int, int)>>[
      <(int, int)>[(1000, 1500)],
    ]);
  });

  test('readUnitsLength 求子区间总长', () {
    expect(readUnitsLength(const <(int, int)>[]), 0);
    expect(readUnitsLength(const <(int, int)>[(0, 5), (10, 12)]), 7);
  });
}
