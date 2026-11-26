import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// 定时备份到期判定（app 定时还原点与服务端自动整机备份共用，本地时间）。
void main() {
  const int at4 = 4 * 60;

  test('关着（间隔 0）永不到期；从没满足过立刻到期', () {
    final DateTime now = DateTime(2026, 11, 25, 9);
    expect(
      isBackupSlotDue(intervalDays: 0, now: now, lastSatisfied: null),
      isFalse,
    );
    expect(
      isBackupSlotDue(intervalDays: 1, now: now, lastSatisfied: null),
      isTrue,
    );
  });

  test('偏好时刻：没到 T 不跑，过了 T 跑；错过了 T 下次检查补跑', () {
    final DateTime last = DateTime(2026, 11, 24, 4, 1);
    bool due(DateTime now) => isBackupSlotDue(
      intervalDays: 1,
      preferredMinuteOfDay: at4,
      now: now,
      lastSatisfied: last,
    );
    expect(due(DateTime(2026, 11, 25, 3, 59)), isFalse);
    expect(due(DateTime(2026, 11, 25, 4)), isTrue);
    // 停机错过了 4:00，下午启动补跑。
    expect(due(DateTime(2026, 11, 25, 15)), isTrue);
    // 补跑之后当天不再跑，次日 4:00 重新对齐。
    expect(
      isBackupSlotDue(
        intervalDays: 1,
        preferredMinuteOfDay: at4,
        now: DateTime(2026, 11, 25, 23),
        lastSatisfied: DateTime(2026, 11, 25, 15),
      ),
      isFalse,
    );
  });

  test('间隔按日历日：3 天 / 每周', () {
    final DateTime last = DateTime(2026, 11, 20, 4, 5);
    expect(
      isBackupSlotDue(
        intervalDays: 3,
        preferredMinuteOfDay: at4,
        now: DateTime(2026, 11, 22, 12),
        lastSatisfied: last,
      ),
      isFalse,
    );
    expect(
      isBackupSlotDue(
        intervalDays: 3,
        preferredMinuteOfDay: at4,
        now: DateTime(2026, 11, 23, 4),
        lastSatisfied: last,
      ),
      isTrue,
    );
    expect(
      isBackupSlotDue(
        intervalDays: 7,
        preferredMinuteOfDay: at4,
        now: DateTime(2026, 11, 26, 12),
        lastSatisfied: last,
      ),
      isFalse,
    );
    expect(
      isBackupSlotDue(
        intervalDays: 7,
        preferredMinuteOfDay: at4,
        now: DateTime(2026, 11, 27, 4),
        lastSatisfied: last,
      ),
      isTrue,
    );
  });

  test('没有偏好时刻 = 本地零点：每日不要求满 24 小时', () {
    expect(
      isBackupSlotDue(
        intervalDays: 1,
        now: DateTime(2026, 11, 25, 8),
        lastSatisfied: DateTime(2026, 11, 24, 9),
      ),
      isTrue,
    );
  });

  test('时钟往回调：上次满足在未来 → 到期一次', () {
    expect(
      isBackupSlotDue(
        intervalDays: 1,
        preferredMinuteOfDay: at4,
        now: DateTime(2026, 11, 25, 12),
        lastSatisfied: DateTime(2026, 12, 1, 4),
      ),
      isTrue,
    );
  });

  test('上次在这一时段被打断：本时段不重跑，下一个时段再试', () {
    final DateTime last = DateTime(2026, 11, 24, 4, 1);
    final DateTime interrupted = DateTime(2026, 11, 25, 4, 2);
    expect(
      isBackupSlotDue(
        intervalDays: 1,
        preferredMinuteOfDay: at4,
        now: DateTime(2026, 11, 25, 9),
        lastSatisfied: last,
        lastInterrupted: interrupted,
      ),
      isFalse,
    );
    expect(
      isBackupSlotDue(
        intervalDays: 1,
        preferredMinuteOfDay: at4,
        now: DateTime(2026, 11, 26, 4),
        lastSatisfied: last,
        lastInterrupted: interrupted,
      ),
      isTrue,
    );
  });

  test('latestBackupSlot：今天的 T 没到取昨天的', () {
    expect(
      latestBackupSlot(DateTime(2026, 11, 25, 3), at4),
      DateTime(2026, 11, 24, 4),
    );
    expect(
      latestBackupSlot(DateTime(2026, 11, 25, 4), at4),
      DateTime(2026, 11, 25, 4),
    );
    expect(
      latestBackupSlot(DateTime(2026, 3, 1, 1), at4),
      DateTime(2026, 2, 28, 4),
    );
  });
}
