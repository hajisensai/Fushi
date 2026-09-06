import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「今日」重置时刻：dateKey 派生的唯一输入是 [FushiDatabase.statDayResetHour]，
/// 写入时把时刻前移该小时数再取日历日；读取面全走 key 算术。
void main() {
  tearDown(() {
    FushiDatabase.statDayResetHour = 0;
  });

  group('statDateKeyOf', () {
    test('重置 = 0：与日历日一致', () {
      FushiDatabase.statDayResetHour = 0;
      expect(
        FushiDatabase.statDateKeyOf(DateTime(2026, 9, 6, 0)),
        '2026-09-06',
      );
      expect(
        FushiDatabase.statDateKeyOf(DateTime(2026, 9, 6, 23, 59, 59)),
        '2026-09-06',
      );
    });

    test('重置 = 4：凌晨 2 点属「昨日」、4 点整起属今日', () {
      FushiDatabase.statDayResetHour = 4;
      expect(
        FushiDatabase.statDateKeyOf(DateTime(2026, 9, 6, 2)),
        '2026-09-05',
      );
      expect(
        FushiDatabase.statDateKeyOf(DateTime(2026, 9, 6, 3, 59, 59)),
        '2026-09-05',
      );
      expect(
        FushiDatabase.statDateKeyOf(DateTime(2026, 9, 6, 4)),
        '2026-09-06',
      );
      expect(
        FushiDatabase.statDateKeyOf(DateTime(2026, 9, 6, 23)),
        '2026-09-06',
      );
    });

    test('重置跨月 / 跨年前移按日历', () {
      FushiDatabase.statDayResetHour = 6;
      expect(
        FushiDatabase.statDateKeyOf(DateTime(2026, 3, 1, 5)),
        '2026-02-28',
      );
      expect(
        FushiDatabase.statDateKeyOf(DateTime(2026, 1, 1, 0, 30)),
        '2025-12-31',
      );
    });

    test('setter 夹到 0..23', () {
      FushiDatabase.statDayResetHour = 99;
      expect(FushiDatabase.statDayResetHour, 23);
      FushiDatabase.statDayResetHour = -3;
      expect(FushiDatabase.statDayResetHour, 0);
    });
  });

  group('key 算术', () {
    test('statCalendarDayKeyOf 零填充、不受重置时刻影响', () {
      FushiDatabase.statDayResetHour = 12;
      expect(
        FushiDatabase.statCalendarDayKeyOf(DateTime(2026, 7, 5)),
        '2026-07-05',
      );
      expect(
        FushiDatabase.statCalendarDayKeyOf(DateTime(2026, 7, 5, 1)),
        '2026-07-05',
        reason: '日历日 key 只看年月日，凌晨 1 点仍是 07-05',
      );
    });

    test('statDateKeyToDay 往返、非法格式抛 FormatException', () {
      expect(
        FushiDatabase.statDateKeyToDay('2026-09-06'),
        DateTime(2026, 9, 6),
      );
      expect(
        FushiDatabase.statCalendarDayKeyOf(
          FushiDatabase.statDateKeyToDay('2025-12-31'),
        ),
        '2025-12-31',
      );
      expect(
        () => FushiDatabase.statDateKeyToDay('2026-09'),
        throwsFormatException,
      );
    });

    test('statDateKeyPlusDays 跨月 / 跨年 / 负数', () {
      expect(FushiDatabase.statDateKeyPlusDays('2026-08-29', -6), '2026-08-23');
      expect(FushiDatabase.statDateKeyPlusDays('2026-01-03', -6), '2025-12-28');
      expect(FushiDatabase.statDateKeyPlusDays('2026-02-28', 1), '2026-03-01');
      expect(FushiDatabase.statDateKeyPlusDays('2026-12-31', 1), '2027-01-01');
      expect(FushiDatabase.statDateKeyPlusDays('2026-09-06', 0), '2026-09-06');
    });
  });

  group('untilNextStatDayBoundary', () {
    test('重置 = 0：等价于到次日 0 点', () {
      FushiDatabase.statDayResetHour = 0;
      expect(
        FushiDatabase.untilNextStatDayBoundary(DateTime(2026, 8, 29, 15, 30)),
        const Duration(hours: 8, minutes: 30),
      );
      expect(
        FushiDatabase.untilNextStatDayBoundary(DateTime(2026, 8, 29)),
        const Duration(days: 1),
        reason: '恰在边界：下一次是次日，不是 0',
      );
    });

    test('重置 = 4：边界前取今日 4 点、边界后取次日 4 点', () {
      FushiDatabase.statDayResetHour = 4;
      expect(
        FushiDatabase.untilNextStatDayBoundary(DateTime(2026, 8, 29, 2)),
        const Duration(hours: 2),
      );
      expect(
        FushiDatabase.untilNextStatDayBoundary(DateTime(2026, 8, 29, 4)),
        const Duration(days: 1),
        reason: '恰在 4 点：下一次是次日 4 点',
      );
      expect(
        FushiDatabase.untilNextStatDayBoundary(DateTime(2026, 8, 29, 23)),
        const Duration(hours: 5),
      );
      expect(
        FushiDatabase.untilNextStatDayBoundary(DateTime(2026, 12, 31, 23)),
        const Duration(hours: 5),
        reason: '跨年',
      );
    });
  });
}
