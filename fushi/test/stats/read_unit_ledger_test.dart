import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/read_unit_ledger.dart';

/// 「入账额 = 会话翻过的并集 ∩ [0, 当前位置)」的行为契约（用户 2026-09-06 两次裁定：
/// 翻走即计 + 并集去重；回翻撤回、再前进按并集恢复、从未翻过的不计）。
/// 每条对应 `docs/plans/2026-09-06-read-unit-ledger.md` 边界表的一行。
void main() {
  late List<List<(int, int)>> credits;
  late List<List<(int, int)>> retracts;
  late ReadUnitLedger ledger;

  setUp(() {
    credits = <List<(int, int)>>[];
    retracts = <List<(int, int)>>[];
    ledger = ReadUnitLedger(onCredit: credits.add, onRetract: retracts.add);
  });

  int sum(List<List<(int, int)>> xs) =>
      xs.fold<int>(0, (int a, List<(int, int)> f) => a + readUnitsLength(f));
  int net() => sum(credits) - sum(retracts);

  test('A→B→C 快速连翻：每页在翻走时全额计入，当前页未翻走不计', () {
    ledger.arrive(0, 500);
    expect(credits, isEmpty, reason: '到达不计');
    ledger.arrive(500, 1000);
    expect(credits, <List<(int, int)>>[
      <(int, int)>[(0, 500)],
    ]);
    ledger.arrive(1000, 1500);
    expect(net(), 1000);
    expect(ledger.creditedLength, 1000);
    expect(ledger.current, (1000, 1500));
    expect(retracts, isEmpty);
  });

  test('回翻撤回：位置退到 X，X 之后已入账的撤回；再前翻按并集恢复，不用重读', () {
    ledger
      ..arrive(0, 500)
      ..arrive(500, 1000)
      ..arrive(1000, 1500); // 已计 [0,1000)
    ledger.arrive(500, 1000); // 回翻一页：[1000,1500) 并入并集，位置 500
    expect(retracts, <List<(int, int)>>[
      <(int, int)>[(500, 1000)],
    ]);
    expect(net(), 500);
    ledger.arrive(0, 500); // 再回翻：撤回 [0,500)
    expect(net(), 0);
    expect(ledger.coverage.ranges, <(int, int)>[(0, 1500)], reason: '并集不减');
    ledger.arrive(1500, 2000); // 目录跳到最远处之后：[0,1500) 整段恢复
    expect(credits.last, <(int, int)>[(0, 1500)]);
    expect(net(), 1500);
    ledger.arrive(2000, 2500);
    expect(net(), 2000);
  });

  test('误翻很多页再翻回来：净 0（用户 2026-09-06 第二次裁定）', () {
    ledger.arrive(0, 500);
    for (int p = 1; p <= 10; p++) {
      ledger.arrive(p * 500, (p + 1) * 500); // 按住翻页键扫过去
    }
    expect(net(), 5000);
    ledger.arrive(0, 500); // 翻回起点
    expect(net(), 0, reason: '扫过去的那些页全部撤回');
    ledger.leave(); // 关书：当前页 [0,500) 计
    expect(net(), 500);
  });

  test('读一段、回头查上文、跳回原处：撤回再恢复，净额 = 真读过的', () {
    ledger
      ..arrive(1000, 1500)
      ..arrive(1500, 2000)
      ..arrive(2000, 2500); // 读了 [1000,2000)，正在 [2000,2500)
    ledger.arrive(0, 500); // 回头查开头
    expect(net(), 0, reason: '位置退到 0，之前入账的全部撤回');
    ledger.arrive(2500, 3000); // 进度条跳回去（越过原处）
    expect(
      net(),
      2000,
      reason: '[1000,2500) 恢复 + 回头看的那页 [0,500) 翻走也计；[500,1000) 没翻过不计',
    );
  });

  test('同单元重复 arrive（同页多次采样）不结算、不改当前', () {
    ledger.arrive(0, 500);
    ledger.arrive(0, 500);
    ledger.arrive(0, 500);
    expect(credits, isEmpty);
    expect(ledger.current, (0, 500));
  });

  test('连续模式部分重叠：入账随视口顶部推进，回调给出精确子区间；回滚一点撤回一点', () {
    ledger.arrive(0, 800);
    ledger.arrive(300, 1100); // [0,800) 并入，位置 300
    ledger.arrive(600, 1400); // [300,1100) 并入，位置 600
    expect(credits, <List<(int, int)>>[
      <(int, int)>[(0, 300)],
      <(int, int)>[(300, 600)],
    ]);
    expect(ledger.coverage.ranges, <(int, int)>[(0, 1100)]);
    ledger.arrive(500, 1300); // 往回滚一点
    expect(retracts, <List<(int, int)>>[
      <(int, int)>[(500, 600)],
    ]);
    ledger.leave(); // 关书：位置 = 1300，[0,1300) 翻过的全部入账
    expect(net(), 1300);
  });

  test('leave：并入 + 按终点入账并清空（关书 / 跳走 / 显式跳句）', () {
    ledger.arrive(0, 500);
    ledger.leave();
    expect(net(), 500);
    expect(ledger.current, isNull);
    expect(ledger.position, 500);
    ledger.leave();
    expect(credits.length, 1, reason: '重复 leave 幂等');
  });

  test('跳转：跳走前那页计入，跳过的从未成为当前单元所以不计，落点页翻走时计', () {
    ledger.arrive(0, 500);
    ledger.arrive(5000, 5500); // 目录跳转落点：[0,500) 并入并入账
    expect(net(), 500);
    ledger.arrive(5500, 6000);
    expect(net(), 1000);
    expect(ledger.coverage.covers(500, 5000), isFalse, reason: '跳过的段落不算读过');
  });

  test('往前跳后再往回跳到跳过的区间：撤回落点之后的，跳过的仍不计', () {
    ledger.arrive(0, 500);
    ledger.arrive(5000, 5500);
    ledger.arrive(5500, 6000); // 计 [0,500) + [5000,5500)
    ledger.arrive(2000, 2500); // 跳回中间（从未翻过的区域）
    expect(net(), 500, reason: '[5000,5500) 撤回；[500,2000) 没翻过本来就没计');
  });

  test('rebaseOnNextArrive：同页换边界不并入、不结算，以新边界为当前', () {
    ledger.arrive(1000, 1500);
    ledger.rebaseOnNextArrive();
    ledger.arrive(1000, 1650); // 单页 → 双页
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
    expect(net(), 500, reason: '开书前的 rebase 不影响首页结算');
    ledger.rebaseOnNextArrive();
    ledger.arrive(500, 1000); // 同单元：清旗
    ledger.arrive(1000, 1500); // 正常结算 [500,1000)
    expect(net(), 1000);
  });

  test('discard：丢弃当前不并入不重算；reset：清并集，已入账沉没不撤回，新坐标从零起', () {
    ledger.arrive(0, 500);
    ledger.discard();
    expect(credits, isEmpty);
    expect(ledger.current, isNull);
    ledger
      ..arrive(0, 500)
      ..arrive(500, 1000);
    expect(net(), 500);
    ledger.reset();
    expect(ledger.coverage.isEmpty, isTrue);
    expect(ledger.credited.isEmpty, isTrue);
    expect(ledger.current, isNull);
    expect(retracts, isEmpty, reason: '坐标精化不是重读，已入账的不撤回');
    ledger
      ..arrive(0, 500)
      ..arrive(500, 1000);
    expect(net(), 1000, reason: '坐标系变了，旧覆盖作废、新坐标下重新计');
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

  test('同一次落定先撤回后入账（跨越：位置从已入账区后退到并集空洞前再前进）', () {
    ledger
      ..arrive(0, 500)
      ..arrive(500, 1000)
      ..arrive(3000, 3500) // 跳：计 [0,1000)
      ..arrive(3500, 4000); // 计 [3000,3500)
    ledger.arrive(200, 700); // 回到中间：撤回 [200,1000) + [3000,3500)
    expect(retracts.last, <(int, int)>[(200, 1000), (3000, 3500)]);
    expect(net(), 200);
  });

  test('readUnitsLength 求子区间总长', () {
    expect(readUnitsLength(const <(int, int)>[]), 0);
    expect(readUnitsLength(const <(int, int)>[(0, 5), (10, 12)]), 7);
  });
}
