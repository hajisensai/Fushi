import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

// BUG-892：阅读时长记账把后台挂起/熄屏/睡眠的墙钟时长一次性计入（34h 的书 /
// 单小时 >1h / 凌晨幻影阅读）。根因是 ReadingTimeTracker 的 60s 定时器按墙钟差累加，
// 缺视频侧早有的「异常大间隔整窗丢弃」守卫。本测试锁定移植过来的纯函数
// isContinuousReadingGap / splitReadingTime（对照 video_watch_tracker_test）。
void main() {
  group('isContinuousReadingGap (discard suspend/sleep timer gaps)', () {
    test('normal ~60s heartbeat window is continuous', () {
      expect(
        isContinuousReadingGap(
            DateTime(2026, 7, 18, 9, 0, 0), DateTime(2026, 7, 18, 9, 1, 0)),
        isTrue,
      );
    });

    test('boundary at exactly kMaxReadingGap is still continuous', () {
      final DateTime s = DateTime(2026, 7, 18, 9, 0, 0);
      expect(isContinuousReadingGap(s, s.add(kMaxReadingGap)), isTrue);
    });

    test('overnight background gap (3h) is discarded — kills phantom reading',
        () {
      // 用户报告：整夜挂起后恢复，凌晨 3/5 点被记为在读，单小时 >1h。守卫后此窗整段丢弃。
      final DateTime s = DateTime(2026, 7, 18, 3, 12, 0);
      expect(
        isContinuousReadingGap(s, s.add(const Duration(hours: 3))),
        isFalse,
      );
      expect(
        isContinuousReadingGap(
            s, s.add(kMaxReadingGap + const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('zero / negative gap is not continuous', () {
      final DateTime s = DateTime(2026, 7, 18, 9, 0, 0);
      expect(isContinuousReadingGap(s, s), isFalse);
      expect(
        isContinuousReadingGap(s, s.subtract(const Duration(seconds: 5))),
        isFalse,
      );
    });
  });

  group('splitReadingTime (single-boundary hour/day bucketing)', () {
    test('same hour → single bucket', () {
      final r = splitReadingTime(
          DateTime(2026, 7, 18, 9, 0, 0), DateTime(2026, 7, 18, 9, 0, 45));
      expect(r, [('2026-07-18', 9, 45000)]);
    });

    test('crossing hour boundary → two buckets, neither exceeds its slice', () {
      final r = splitReadingTime(
          DateTime(2026, 7, 18, 9, 59, 50), DateTime(2026, 7, 18, 10, 0, 10));
      expect(r.length, 2);
      expect(r[0], ('2026-07-18', 9, 10000));
      expect(r[1], ('2026-07-18', 10, 10000));
    });

    test('crossing midnight → two days', () {
      final r = splitReadingTime(
          DateTime(2026, 7, 18, 23, 59, 50), DateTime(2026, 7, 19, 0, 0, 10));
      expect(r.length, 2);
      expect(r[0], ('2026-07-18', 23, 10000));
      expect(r[1], ('2026-07-19', 0, 10000));
    });

    test('zero elapsed → empty', () {
      expect(
        splitReadingTime(
            DateTime(2026, 7, 18, 9, 0, 0), DateTime(2026, 7, 18, 9, 0, 0)),
        isEmpty,
      );
    });

    // REGRESSION（坐实根因）：撤掉 isContinuousReadingGap 守卫、直接把整段 splitReadingTime
    // 结果计入，一个小时桶会被灌进远超 3600000ms 的时长——正是「单小时 >2.5h」症状。
    test('unguarded multi-hour gap dumps >1h into a single bucket', () {
      final r = splitReadingTime(
          DateTime(2026, 7, 18, 3, 0, 0), DateTime(2026, 7, 18, 5, 30, 0));
      // 第二个桶（5 点）拿到 2.5h，远超一小时上限——守卫存在的理由。
      final int fivePmBucketMs = r.firstWhere((e) => e.$2 == 5).$3;
      expect(fivePmBucketMs, greaterThan(3600000));
      // 但 isContinuousReadingGap 会先把这种输入挡在门外，所以生产路径 _flush 永不喂它。
      expect(
        isContinuousReadingGap(
            DateTime(2026, 7, 18, 3, 0, 0), DateTime(2026, 7, 18, 5, 30, 0)),
        isFalse,
      );
    });
  });

  group('BUG-892 lifecycle wiring guards (reader page)', () {
    late String src;
    setUpAll(() {
      src = File('lib/src/pages/implementations/reader_hibiki_page.dart')
          .readAsStringSync();
    });

    test('进后台/失焦时停掉阅读计时器', () {
      final int i = src.indexOf('didChangeAppLifecycleState');
      expect(i, greaterThanOrEqualTo(0));
      final int resumed = src.indexOf('AppLifecycleState.resumed', i);
      // paused/inactive 分支（resumed 之前）里停 tracker。
      final String pausedBranch = src.substring(i, resumed);
      expect(pausedBranch.contains('_readingTimeTracker?.stop()'), isTrue,
          reason: 'BUG-892 回归：后台不停计时 → 挂起时长被计入');
    });

    test('恢复前台时重置会话计时起点并重启计时器', () {
      final int resumed = src.indexOf('AppLifecycleState.resumed');
      final String resumedBranch = src.substring(resumed, resumed + 600);
      expect(
          resumedBranch.contains('_sessionStartTime = DateTime.now()'), isTrue,
          reason: 'BUG-892：不重置 _sessionStartTime → 每书时长把后台段算进下次 flush');
      expect(resumedBranch.contains('_readingTimeTracker?.start()'), isTrue);
    });
  });
}
