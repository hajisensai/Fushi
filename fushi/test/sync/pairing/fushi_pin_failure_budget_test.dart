import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:test/test.dart';

/// BUG-4390：按来源类别的 PIN 失败总预算——窗口内累计到阈值即锁定，锁定时长按级数
/// 翻倍、封顶；配对成功 / 管理员解除清零；长时间无失败级数归零。
void main() {
  final DateTime t0 = DateTime.utc(2026, 11, 10, 12);

  /// 每分钟失败一次，连续 [n] 次；返回最后一次 recordFailure 的结果。
  bool failTimes(FushiPinFailureBudget b, int n, DateTime start) {
    bool locked = false;
    for (int i = 0; i < n; i++) {
      locked = b.recordFailure(start.add(Duration(minutes: i)));
    }
    return locked;
  }

  test('窗口内 10 次失败锁 15 分钟，第 9 次还不锁', () {
    final FushiPinFailureBudget b = FushiPinFailureBudget();
    expect(failTimes(b, 9, t0), isFalse);
    expect(b.isLockedOut(t0.add(const Duration(minutes: 9))), isFalse);
    expect(b.recordFailure(t0.add(const Duration(minutes: 9))), isTrue);
    expect(b.lockedUntil, t0.add(const Duration(minutes: 9 + 15)));
    expect(b.level, 1);
    expect(b.isLockedOut(t0.add(const Duration(minutes: 23))), isTrue);
    expect(b.isLockedOut(t0.add(const Duration(minutes: 24))), isFalse);
  });

  test('失败间隔超过窗口则计数从头开始', () {
    final FushiPinFailureBudget b = FushiPinFailureBudget();
    expect(failTimes(b, 9, t0), isFalse);
    // 距上次失败 16 分钟：窗口已过，这一次算第 1 次。
    final DateTime later = t0.add(const Duration(minutes: 8 + 16));
    expect(b.recordFailure(later), isFalse);
    expect(failTimes(b, 8, later.add(const Duration(minutes: 1))), isFalse);
  });

  test('锁满后再 10 次锁 30 分钟，逐级翻倍并封顶 24 小时', () {
    final FushiPinFailureBudget b = FushiPinFailureBudget();
    DateTime now = t0;
    final List<Duration> lockouts = <Duration>[];
    for (int round = 0; round < 9; round++) {
      expect(failTimes(b, 10, now), isTrue);
      final DateTime lockedAt = now.add(const Duration(minutes: 9));
      lockouts.add(b.lockedUntil!.difference(lockedAt));
      now = b.lockedUntil!;
      expect(b.isLockedOut(now), isFalse);
    }
    expect(lockouts.take(4), const <Duration>[
      Duration(minutes: 15),
      Duration(minutes: 30),
      Duration(minutes: 60),
      Duration(minutes: 120),
    ]);
    expect(lockouts.last, const Duration(hours: 24));
  });

  test('锁定期间再记失败不延长锁定也不累计', () {
    final FushiPinFailureBudget b = FushiPinFailureBudget();
    failTimes(b, 10, t0);
    final DateTime? until = b.lockedUntil;
    expect(b.recordFailure(t0.add(const Duration(minutes: 10))), isTrue);
    expect(b.lockedUntil, until);
    expect(b.level, 1);
  });

  test('recordSuccess 清零级数与计数', () {
    final FushiPinFailureBudget b = FushiPinFailureBudget();
    failTimes(b, 10, t0);
    final DateTime after = b.lockedUntil!;
    failTimes(b, 9, after);
    b.recordSuccess();
    expect(b.level, 0);
    // 计数也清了：再 9 次不锁，第 10 次锁，且回到 15 分钟这一级。
    final DateTime next = after.add(const Duration(minutes: 20));
    expect(failTimes(b, 9, next), isFalse);
    expect(b.recordFailure(next.add(const Duration(minutes: 9))), isTrue);
    expect(
      b.lockedUntil,
      next.add(const Duration(minutes: 9)).add(const Duration(minutes: 15)),
    );
  });

  test('reset 立即解除锁定并清零', () {
    final FushiPinFailureBudget b = FushiPinFailureBudget();
    failTimes(b, 10, t0);
    expect(b.isLockedOut(t0.add(const Duration(minutes: 10))), isTrue);
    b.reset();
    expect(b.isLockedOut(t0.add(const Duration(minutes: 10))), isFalse);
    expect(b.lockedUntil, isNull);
    expect(b.level, 0);
  });

  test('24 小时没有失败，级数归零', () {
    final FushiPinFailureBudget b = FushiPinFailureBudget();
    failTimes(b, 10, t0);
    failTimes(b, 10, b.lockedUntil!);
    expect(b.level, 2);
    final DateTime muchLater = b.lockedUntil!.add(const Duration(hours: 25));
    expect(failTimes(b, 10, muchLater), isTrue);
    expect(
      b.lockedUntil,
      muchLater.add(const Duration(minutes: 9 + 15)),
      reason: '级数已衰减回 0，这次只锁 15 分钟',
    );
    expect(b.level, 1);
  });
}
