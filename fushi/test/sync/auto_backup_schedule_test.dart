import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_schedule.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_settings.dart';

/// 自动备份的到期判定（本地时间）。
void main() {
  const AutoBackupSettings daily = AutoBackupSettings();
  const AutoBackupSettings every3 = AutoBackupSettings(
    interval: AutoBackupInterval.every3Days,
  );

  group('没有偏好时刻：距上次满足满 N 天', () {
    test('从没满足过立刻到期；关着永不到期', () {
      final DateTime now = DateTime(2026, 11, 25, 9);
      expect(
        isAutoBackupDue(settings: daily, now: now, lastSatisfied: null),
        isTrue,
      );
      expect(
        isAutoBackupDue(
          settings: const AutoBackupSettings(interval: AutoBackupInterval.off),
          now: now,
          lastSatisfied: null,
        ),
        isFalse,
      );
    });

    test('间隔按天数算', () {
      final DateTime last = DateTime(2026, 11, 20, 9);
      bool due(AutoBackupSettings s, DateTime now) =>
          isAutoBackupDue(settings: s, now: now, lastSatisfied: last);
      expect(due(daily, DateTime(2026, 11, 21, 8, 59)), isFalse);
      expect(due(daily, DateTime(2026, 11, 21, 9)), isTrue);
      expect(due(every3, DateTime(2026, 11, 22, 23)), isFalse);
      expect(due(every3, DateTime(2026, 11, 23, 9)), isTrue);
      const AutoBackupSettings weekly = AutoBackupSettings(
        interval: AutoBackupInterval.weekly,
      );
      expect(due(weekly, DateTime(2026, 11, 26, 9)), isFalse);
      expect(due(weekly, DateTime(2026, 11, 27, 9)), isTrue);
    });
  });

  group('有偏好时刻：对齐到 T，错过了补跑', () {
    const AutoBackupSettings nightly = AutoBackupSettings(
      preferredMinuteOfDay: 22 * 60,
    );

    test('最近一个已过去的时刻', () {
      expect(
        latestAutoBackupSlot(DateTime(2026, 11, 25, 23), 22 * 60),
        DateTime(2026, 11, 25, 22),
      );
      expect(
        latestAutoBackupSlot(DateTime(2026, 11, 25, 21, 59), 22 * 60),
        DateTime(2026, 11, 24, 22),
      );
      expect(
        latestAutoBackupSlot(DateTime(2026, 11, 25, 22), 22 * 60),
        DateTime(2026, 11, 25, 22),
      );
    });

    test('每日：今天的 T 过了且上次早于它才到期', () {
      final DateTime last = DateTime(2026, 11, 24, 22, 5);
      bool due(DateTime now) =>
          isAutoBackupDue(settings: nightly, now: now, lastSatisfied: last);
      expect(due(DateTime(2026, 11, 25, 21)), isFalse);
      expect(due(DateTime(2026, 11, 25, 22)), isTrue);
    });

    test('app 关着错过 T：下次启动补跑（catch-up），之后重新对齐', () {
      // 上次是 3 天前的 22:05；今天早上 8 点才打开 → 昨晚的 T 错过了 → 立刻到期。
      expect(
        isAutoBackupDue(
          settings: nightly,
          now: DateTime(2026, 11, 25, 8),
          lastSatisfied: DateTime(2026, 11, 22, 22, 5),
        ),
        isTrue,
      );
      // 补跑在 8:01 完成：今晚 22 点之前不再到期，22 点之后到期。
      final DateTime caughtUp = DateTime(2026, 11, 25, 8, 1);
      expect(
        isAutoBackupDue(
          settings: nightly,
          now: DateTime(2026, 11, 25, 21, 59),
          lastSatisfied: caughtUp,
        ),
        isFalse,
      );
      expect(
        isAutoBackupDue(
          settings: nightly,
          now: DateTime(2026, 11, 25, 22, 1),
          lastSatisfied: caughtUp,
        ),
        isTrue,
      );
    });

    test('每 3 天：上次早于「最近的 T 往前 2 天」才到期', () {
      const AutoBackupSettings s = AutoBackupSettings(
        interval: AutoBackupInterval.every3Days,
        preferredMinuteOfDay: 22 * 60,
      );
      final DateTime last = DateTime(2026, 11, 20, 22, 5);
      bool due(DateTime now) =>
          isAutoBackupDue(settings: s, now: now, lastSatisfied: last);
      expect(due(DateTime(2026, 11, 22, 23)), isFalse);
      expect(due(DateTime(2026, 11, 23, 21)), isFalse);
      expect(due(DateTime(2026, 11, 23, 22)), isTrue);
    });
  });

  test('告警：上次满足早于两个间隔之前', () {
    final DateTime last = DateTime(2026, 11, 20, 9);
    expect(
      isAutoBackupOverdue(
        settings: daily,
        now: DateTime(2026, 11, 22, 9),
        lastSatisfied: last,
      ),
      isFalse,
    );
    expect(
      isAutoBackupOverdue(
        settings: daily,
        now: DateTime(2026, 11, 22, 10),
        lastSatisfied: last,
      ),
      isTrue,
    );
    expect(
      isAutoBackupOverdue(
        settings: const AutoBackupSettings(interval: AutoBackupInterval.off),
        now: DateTime(2027),
        lastSatisfied: last,
      ),
      isFalse,
    );
  });
}
