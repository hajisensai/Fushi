// 睡眠定时的通知契约（Round7 审查「睡眠分钟提示陈旧」候选）：歌词覆盖层只随
// 控制器通知重建，暂停时控制器不通知——剩余分钟的变化与到点熄灭必须由定时器
// 自己通知，否则按钮提示停在开定时那一刻、暂停中到点后仍亮着。
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_audiobook_panel.dart';

void main() {
  tearDown(() => AudiobookSleepTimer.now = DateTime.now);

  test('notifies on start, every minute boundary and on expiry', () {
    fakeAsync((FakeAsync async) {
      final DateTime origin = DateTime(2026, 10, 6, 12);
      AudiobookSleepTimer.now = () => origin.add(async.elapsed);
      int expired = 0;
      final AudiobookSleepTimer timer = AudiobookSleepTimer.forTesting(
        onExpire: () => expired++,
      );
      final List<int?> seen = <int?>[];
      timer.addListener(() => seen.add(timer.remainingMinutes));

      timer.start(3);
      expect(seen, <int?>[3]);

      async.elapse(const Duration(seconds: 30));
      expect(timer.remainingMinutes, 3);
      expect(seen, <int?>[3], reason: 'no change inside the same minute');

      async.elapse(const Duration(seconds: 31));
      expect(seen, <int?>[3, 2]);

      async.elapse(const Duration(minutes: 1));
      expect(seen, <int?>[3, 2, 1]);
      expect(expired, 0);

      async.elapse(const Duration(minutes: 1));
      expect(expired, 1);
      expect(timer.remainingMinutes, isNull);
      expect(seen, <int?>[3, 2, 1, null]);

      async.elapse(const Duration(minutes: 5));
      expect(seen, <int?>[3, 2, 1, null], reason: 'no ticks after expiry');
    });
  });

  test('turning the timer off notifies and stops minute ticks', () {
    fakeAsync((FakeAsync async) {
      final DateTime origin = DateTime(2026, 10, 6, 12);
      AudiobookSleepTimer.now = () => origin.add(async.elapsed);
      int expired = 0;
      final AudiobookSleepTimer timer = AudiobookSleepTimer.forTesting(
        onExpire: () => expired++,
      );
      final List<int?> seen = <int?>[];
      timer.addListener(() => seen.add(timer.remainingMinutes));

      timer.start(15);
      async.elapse(const Duration(minutes: 2, seconds: 1));
      expect(seen, <int?>[15, 14, 13]);

      timer.start(null);
      expect(seen, <int?>[15, 14, 13, null]);
      async.elapse(const Duration(minutes: 20));
      expect(seen, <int?>[15, 14, 13, null]);
      expect(expired, 0);
    });
  });
}
