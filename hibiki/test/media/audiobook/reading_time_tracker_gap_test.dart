import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/source_guard.dart';

// BUG-892：阅读时长记账把后台挂起/熄屏/睡眠的墙钟时长一次性计入（34h 的书 /
// 单小时 >1h / 凌晨幻影阅读）。根因是 ReadingTimeTracker 的 60s 定时器按墙钟差累加，
// 缺视频侧早有的「异常大间隔整窗丢弃」守卫。本测试锁定移植过来的纯函数
// isContinuousReadingGap / splitReadingTime（对照 video_watch_tracker_test）。
//
// 下面的源码守卫一律先跑共享的 [maskComments] 再匹配——本轮修复的注释里**刻意**
// 保留了旧字段名（`_sessionStartTime`）作为历史说明，不能让它把「字段已删除」的
// 断言判假。旧的本地 `_codeOnly` 只丢掉整行 `//` 开头的行，`/* _sessionStartTime =
// DateTime.now(); */` 这类块注释与行尾注释一概放行；而且「整行删除」会改变长度，
// 底下那些 `indexOf(锚点)` + `substring(i, i + N)` 的窗口全部落在一份与原文行号
// 错位的文本上。[maskComments] 换成**等长空白**，窗口下标与原文逐字节对齐。

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
      src = maskComments(
          File('lib/src/pages/implementations/reader_hibiki_page.dart')
              .readAsStringSync());
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

    test('恢复前台时重启计时器（后台段靠「计时器停着」丢弃，不靠重锚墙钟）', () {
      final int resumed = src.indexOf('AppLifecycleState.resumed');
      final String resumedBranch = src.substring(resumed, resumed + 900);
      expect(resumedBranch.contains('_readingTimeTracker?.start()'), isTrue,
          reason: 'BUG-892：不重启小时桶计时器 → 回前台后阅读时长不再记账');
      // BUG-1052：这里曾经是 `_sessionStartTime = DateTime.now()`。那个重锚在丢弃
      // 后台段的同时，把**重锚前那段还没落库的前台阅读时长**一并抹掉（`_flushReadingStats`
      // 以 `_sessionCharsRead <= 0` 早退时根本不消费它）。查词频繁 = 失焦/回前台频繁
      // = 几乎全部时长蒸发。现在后台段由「tracker 停着不 tick」天然排除，无需重锚。
      expect(resumedBranch.contains('_sessionStartTime'), isFalse,
          reason: 'BUG-1052 回归：resumed 重锚墙钟基准会吃掉未落库的前台阅读时长');
    });
  });

  // ── BUG-1052：每书/每日时长与小时桶必须共用同一个带守卫的时钟 ──────────────
  //
  // 症状（用户 2026-07-23 反馈截图）：今日 1832 字 / 时长 0 分钟 / 速度 125666 字·时⁻¹，
  // 「最快日」421249 字·时⁻¹。生产库对账坐实——同一天 reading_statistics 记 84 分钟，
  // reading_hourly_logs 记 345 分钟；两条账目差 4 倍以上，前者是错的那条。
  group('BUG-1052 单一时钟：会话时长累计器不被任何重锚吃掉', () {
    test('EPUB 阅读器不再持有可被重置的墙钟基准字段', () {
      final String page = maskComments(
          File('lib/src/pages/implementations/reader_hibiki_page.dart')
              .readAsStringSync());
      final String nav = maskComments(File(
              'lib/src/pages/implementations/reader_hibiki/navigation.part.dart')
          .readAsStringSync());
      // 字段本体必须已删除（注释里可以留历史说明，故只查声明与赋值形态）。
      expect(page.contains('DateTime _sessionStartTime'), isFalse);
      expect(page.contains('_sessionStartTime ='), isFalse);
      expect(nav.contains('_sessionStartTime ='), isFalse);
      // 取而代之：由 tracker 的 onDelta 累加的会话累计器。
      expect(page.contains('int _sessionReadingMs = 0'), isTrue);
      expect(nav.contains('onDelta:'), isTrue);
      expect(nav.contains('_sessionReadingMs += deltaMs'), isTrue);
    });

    test('恢复完成（每次重排版都会跑）不得重锚会话时钟', () {
      final String nav = maskComments(File(
              'lib/src/pages/implementations/reader_hibiki/navigation.part.dart')
          .readAsStringSync());
      final int i = nav.indexOf('void _onRestoreComplete()');
      expect(i, greaterThanOrEqualTo(0));
      final int end = nav.indexOf('\n  void ', i + 10);
      final String body = nav.substring(i, end > i ? end : i + 4000);
      expect(body.contains('_sessionStartTime'), isFalse,
          reason: 'BUG-1052 回归：重排版/重恢复会抹掉上一段未落库的阅读时长');
      expect(body.contains('_sessionReadingMs = 0'), isFalse,
          reason: 'BUG-1052 回归：恢复完成不得清空会话时长累计器');
    });

    test('无新字数的早退路径不清空累计器（时长留到下次落库）', () {
      final String nav = maskComments(File(
              'lib/src/pages/implementations/reader_hibiki/navigation.part.dart')
          .readAsStringSync());
      final int i = nav.indexOf('Future<void> _flushReadingStats()');
      expect(i, greaterThanOrEqualTo(0));
      final String body = nav.substring(i, math.min(i + 1600, nav.length));
      final int guard = body.indexOf('_sessionCharsRead <= 0');
      final int clear = body.indexOf('_sessionReadingMs = 0');
      expect(guard, greaterThanOrEqualTo(0));
      expect(clear, greaterThan(guard), reason: 'BUG-1052：累计器只能在真正落库那条路径上清零');
      // 落库前必须先把「上一次 tick 到现在」这段补进累计器。
      expect(body.indexOf('sampleNow()'), inInclusiveRange(0, guard),
          reason: 'BUG-1052：不 sampleNow 每次落库都漏掉最多一个 tick 间隔');
    });

    test('PDF 阅读器不再拿整段会话去过一次 gap 守卫', () {
      final String pdf = maskComments(
          File('lib/src/pages/implementations/reader_pdf_page.dart')
              .readAsStringSync());
      expect(pdf.contains('DateTime _sessionStartTime'), isFalse);
      expect(pdf.contains('int _sessionReadingMs = 0'), isTrue);
      final int i = pdf.indexOf('Future<void> _flushReadingStats()');
      expect(i, greaterThanOrEqualTo(0));
      final String body = pdf.substring(i, i + 1400);
      // 旧写法：if (!isContinuousReadingGap(now - elapsed, now)) return;
      // → 任何 >120s 的正常 PDF 阅读会话被整段丢弃，读多久都记 0。
      expect(body.contains('isContinuousReadingGap('), isFalse,
          reason: 'BUG-1052 回归：整段会话过守卫 = 长会话时长恒为 0');
      expect(body.contains('sampleNow()'), isTrue);
    });
  });
}
