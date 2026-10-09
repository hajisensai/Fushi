import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi_core/fushi_core.dart';

// v92：统计窗口阈值只有一个定义。此前四处手算 `now - 7d` 并 `>=` 比较，「近 7 天」
// 实际 8 天、「近 30 天」31 天，环比分母却恰 7 天——本周系统性偏大、环比结构性偏正。
void main() {
  final StatWindow w = StatWindow(DateTime(2026, 8, 29, 15, 30));

  test('本周 = 自然周（周一起）；近 7 天恰 7 个自然日（含今日）', () {
    // 2026-08-29 是周六。
    expect(w.todayKey, '2026-08-29');
    expect(w.weekFromKey, '2026-08-24');
    expect(w.inWeek('2026-08-24'), isTrue, reason: '周一属本周');
    expect(w.inWeek('2026-08-23'), isFalse, reason: '上周日不属本周');
    expect(w.inWeek('2026-08-29'), isTrue);
    expect(w.inWeek('2026-08-30'), isFalse, reason: '未来日期不算');
    expect(w.lastDayKeys(7), hasLength(7));
    expect(w.lastDayKeys(7).first, '2026-08-23');
    expect(w.lastDayKeys(7).last, '2026-08-29');
  });

  test('上周 = 上周同期：与本周已过天数同长、不重叠', () {
    expect(w.prevWeekFromKey, '2026-08-17');
    expect(w.prevWeekToKey, '2026-08-22');
    expect(w.inPrevWeek('2026-08-17'), isTrue);
    expect(w.inPrevWeek('2026-08-22'), isTrue);
    expect(w.inPrevWeek('2026-08-23'), isFalse, reason: '上周日超出同期');
    expect(w.inPrevWeek('2026-08-24'), isFalse, reason: '本周首日不属于上周');
    expect(w.inPrevWeek('2026-08-16'), isFalse);
    // 周一：本周只有今天，上周同期只有上周一。
    final StatWindow monday = StatWindow(DateTime(2026, 8, 24, 9));
    expect(monday.weekFromKey, '2026-08-24');
    expect(monday.prevWeekFromKey, '2026-08-17');
    expect(monday.prevWeekToKey, '2026-08-17');
  });

  test('近 30 天恰 30 个自然日', () {
    expect(w.monthFromKey, '2026-07-31');
    expect(w.inMonth('2026-07-31'), isTrue);
    expect(w.inMonth('2026-07-30'), isFalse);
    expect(w.lastDayKeys(30), hasLength(30));
    expect(w.lastDayKeys(30).first, '2026-07-31');
  });

  tearDown(() {
    FushiDatabase.statDayResetHour = 0;
  });

  test(
    'untilNextStatDayBoundary（重置 = 0）：到次日 0 点，恒 > 0',
    () {
      expect(
        StatWindow.untilNextStatDayBoundary(DateTime(2026, 8, 29, 15, 30)),
        const Duration(hours: 8, minutes: 30),
      );
      expect(
        StatWindow.untilNextStatDayBoundary(
          DateTime(2026, 8, 29, 23, 59, 59, 999),
        ),
        const Duration(milliseconds: 1),
      );
      expect(
        StatWindow.untilNextStatDayBoundary(DateTime(2026, 8, 29)),
        const Duration(days: 1),
        reason: '恰在 0 点：下一次午夜是次日，不是 0',
      );
      expect(
        StatWindow.untilNextStatDayBoundary(DateTime(2026, 12, 31, 23)),
        const Duration(hours: 1),
        reason: '跨年',
      );
    },
  );

  test('跨月 / 跨年边界按日历减天', () {
    final StatWindow ny = StatWindow(DateTime(2026, 1, 3));
    expect(ny.weekFromKey, '2025-12-29', reason: '跨年的自然周从上年周一起');
    expect(ny.monthFromKey, '2025-12-05');
  });

  group('「今日」重置时刻 = 4', () {
    setUp(() {
      FushiDatabase.statDayResetHour = 4;
    });

    test('凌晨 2 点仍属昨日：todayKey 与所有窗口起点整体前移一天', () {
      final StatWindow early = StatWindow(DateTime(2026, 8, 30, 2));
      expect(early.todayKey, '2026-08-29');
      expect(early.weekFromKey, '2026-08-24');
      expect(early.prevWeekFromKey, '2026-08-17');
      expect(early.monthFromKey, '2026-07-31');
      expect(early.lastDayKeys(7).last, '2026-08-29');
      expect(early.inWeek('2026-08-30'), isFalse, reason: '日历今日还没开始');
    });

    test('4 点整起是今日', () {
      final StatWindow late = StatWindow(DateTime(2026, 8, 30, 4));
      expect(late.todayKey, '2026-08-30');
      expect(late.weekFromKey, '2026-08-24');
    });

    test('untilNextStatDayBoundary 取 4 点边界', () {
      expect(
        StatWindow.untilNextStatDayBoundary(DateTime(2026, 8, 30, 2)),
        const Duration(hours: 2),
      );
      expect(
        StatWindow.untilNextStatDayBoundary(DateTime(2026, 8, 30, 4)),
        const Duration(days: 1),
      );
    });
  });
}
