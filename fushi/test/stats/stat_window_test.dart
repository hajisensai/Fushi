import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/stat_window.dart';

// v90：统计窗口阈值只有一个定义。此前四处手算 `now - 7d` 并 `>=` 比较，「近 7 天」
// 实际 8 天、「近 30 天」31 天，环比分母却恰 7 天——本周系统性偏大、环比结构性偏正。
void main() {
  final StatWindow w = StatWindow(DateTime(2026, 8, 29, 15, 30));

  test('近 7 天恰 7 个自然日（含今日）', () {
    expect(w.todayKey, '2026-08-29');
    expect(w.weekFromKey, '2026-08-23');
    expect(w.inWeek('2026-08-23'), isTrue);
    expect(w.inWeek('2026-08-22'), isFalse, reason: '第 8 天不在窗口内');
    expect(w.inWeek('2026-08-29'), isTrue);
    expect(w.inWeek('2026-08-30'), isFalse, reason: '未来日期不算');
    expect(w.lastDayKeys(7), hasLength(7));
    expect(w.lastDayKeys(7).first, '2026-08-23');
    expect(w.lastDayKeys(7).last, '2026-08-29');
  });

  test('上一个 7 天窗口与本周不重叠、恰 7 天', () {
    expect(w.prevWeekFromKey, '2026-08-16');
    expect(w.inPrevWeek('2026-08-16'), isTrue);
    expect(w.inPrevWeek('2026-08-22'), isTrue);
    expect(w.inPrevWeek('2026-08-23'), isFalse, reason: '本周首日不属于上周');
    expect(w.inPrevWeek('2026-08-15'), isFalse);
  });

  test('近 30 天恰 30 个自然日', () {
    expect(w.monthFromKey, '2026-07-31');
    expect(w.inMonth('2026-07-31'), isTrue);
    expect(w.inMonth('2026-07-30'), isFalse);
    expect(w.lastDayKeys(30), hasLength(30));
    expect(w.lastDayKeys(30).first, '2026-07-31');
  });

  test('跨月 / 跨年边界按日历减天', () {
    final StatWindow ny = StatWindow(DateTime(2026, 1, 3));
    expect(ny.weekFromKey, '2025-12-28');
    expect(ny.monthFromKey, '2025-12-05');
  });
}
