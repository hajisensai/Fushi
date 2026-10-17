import 'package:fushi_engine/srs/srs_backup_retention.dart';
import 'package:test/test.dart';

/// 保留策略 = Anki rslib `BackupFilter`（今天 / 昨天全留，再按日 12、周 10、月 9）。
void main() {
  List<DateTime> obsolete(
    List<DateTime> backups,
    DateTime now, {
    SrsBackupLimits limits = const SrsBackupLimits(),
  }) => srsObsoleteBackups<DateTime>(
    backups,
    localTimeOf: (DateTime d) => d,
    now: now,
    limits: limits,
  );

  test('默认值对齐 Anki：间隔 30 分钟，日 12 / 周 10 / 月 9', () {
    const SrsBackupLimits l = SrsBackupLimits();
    expect(l.intervalMinutes, 30);
    expect(l.daily, 12);
    expect(l.weekly, 10);
    expect(l.monthly, 9);
  });

  test('今天和昨天的备份全部保留，不消耗名额', () {
    final DateTime now = DateTime(2026, 10, 17, 20);
    final List<DateTime> b = <DateTime>[
      for (int h = 0; h < 20; h++) DateTime(2026, 10, 17, h),
      for (int h = 0; h < 24; h++) DateTime(2026, 10, 16, h),
    ];
    expect(
      obsolete(
        b,
        now,
        limits: const SrsBackupLimits(daily: 0, weekly: 0, monthly: 0),
      ),
      isEmpty,
    );
  });

  test('更早的按天各留最新一份，超出每日名额后按周、再按月，最后全删', () {
    final DateTime now = DateTime(2026, 10, 17, 12);
    // 前天起往前 400 天，每天两份（早 8 点、晚 20 点）。
    final List<DateTime> b = <DateTime>[
      for (int d = 2; d < 400; d++) ...<DateTime>[
        DateTime(2026, 10, 17 - d, 20),
        DateTime(2026, 10, 17 - d, 8),
      ],
    ];
    final Set<DateTime> gone = obsolete(b, now).toSet();
    final List<DateTime> kept =
        b.where((DateTime d) => !gone.contains(d)).toList()
          ..sort((DateTime x, DateTime y) => y.compareTo(x));
    expect(kept, hasLength(12 + 10 + 9));
    // 每日：前天起连续 12 天，每天留当天最新（20 点）那份。
    for (int i = 0; i < 12; i++) {
      expect(kept[i], DateTime(2026, 10, 15 - i, 20));
    }
    // 周：之后每份都在更早的一周；月：之后每份都在更早的一个月。
    int week(DateTime d) => (srsDaysFromCe(d) - 1) ~/ 7;
    for (int i = 12; i < 22; i++) {
      expect(week(kept[i]), lessThan(week(kept[i - 1])));
    }
    int month(DateTime d) => d.year * 12 + d.month;
    for (int i = 22; i < kept.length; i++) {
      expect(month(kept[i]), lessThan(month(kept[i - 1])));
    }
  });

  test('名额可调：每日 1、周月 0 → 只留昨天以前最新的一份', () {
    final DateTime now = DateTime(2026, 10, 17, 12);
    final List<DateTime> b = <DateTime>[
      DateTime(2026, 10, 17, 9),
      DateTime(2026, 10, 14, 9),
      DateTime(2026, 10, 13, 9),
      DateTime(2026, 10, 1, 9),
    ];
    expect(
      obsolete(
        b,
        now,
        limits: const SrsBackupLimits(daily: 1, weekly: 0, monthly: 0),
      ),
      <DateTime>[DateTime(2026, 10, 13, 9), DateTime(2026, 10, 1, 9)],
    );
  });

  test('周从周一开始（rslib：(日序号 - 1) / 7）：周日与紧接的周一属于不同的周', () {
    DateTime sunday = DateTime(2026, 9, 1, 9);
    while (sunday.weekday != DateTime.sunday) {
      sunday = sunday.add(const Duration(days: 1));
    }
    final DateTime monday = sunday.add(const Duration(days: 1));
    final DateTime saturday = sunday.subtract(const Duration(days: 1));
    // 只有每周名额：周一一份、周日一份都留；周六与周日同一周，删。
    expect(
      obsolete(
        <DateTime>[monday, sunday, saturday],
        DateTime(2026, 10, 30, 12),
        limits: const SrsBackupLimits(daily: 0, weekly: 5, monthly: 0),
      ),
      <DateTime>[saturday],
    );
  });

  test('公元日序号与 chrono num_days_from_ce 一致', () {
    expect(srsDaysFromCe(DateTime(1, 1, 1)), 1);
    expect(srsDaysFromCe(DateTime(1970, 1, 1)), 719163);
  });

  group('自动备份触发', () {
    const SrsBackupLimits l = SrsBackupLimits();
    const int min = 60 * 1000;
    test('没有变动不备份（定时、离开复习页都一样）', () {
      for (final bool force in <bool>[false, true]) {
        expect(
          srsShouldAutoBackup(
            currentFingerprint: 'a',
            latestFingerprint: 'a',
            latestCreatedAtMs: 0,
            nowMs: 999 * min,
            limits: l,
            leavingReview: force,
          ),
          isFalse,
        );
      }
    });
    test('有变动：定时要满 30 分钟，离开复习页满 5 分钟', () {
      bool run(int ago, {bool force = false}) => srsShouldAutoBackup(
        currentFingerprint: 'b',
        latestFingerprint: 'a',
        latestCreatedAtMs: 100 * min - ago,
        nowMs: 100 * min,
        limits: l,
        leavingReview: force,
      );
      expect(run(29 * min), isFalse);
      expect(run(30 * min), isTrue);
      expect(run(1 * min, force: true), isFalse);
      expect(run(5 * min, force: true), isTrue);
    });
    test('从没备份过：有数据就备份', () {
      expect(
        srsShouldAutoBackup(
          currentFingerprint: 'b',
          latestFingerprint: null,
          latestCreatedAtMs: null,
          nowMs: 0,
          limits: l,
        ),
        isTrue,
      );
    });
  });
}
