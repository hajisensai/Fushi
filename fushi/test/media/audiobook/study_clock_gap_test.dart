import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/source_guard.dart';

// BUG-892：阅读时长记账把后台挂起/熄屏/睡眠的墙钟时长一次性计入（34h 的书 /
// 单小时 >1h / 凌晨幻影阅读）。根因是旧 ReadingTimeTracker（现 StudyClock）的 60s 定时器按墙钟差累加，
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
          DateTime(2026, 7, 18, 9, 0, 0),
          DateTime(2026, 7, 18, 9, 1, 0),
        ),
        isTrue,
      );
    });

    test('boundary at exactly kMaxReadingGap is still continuous', () {
      final DateTime s = DateTime(2026, 7, 18, 9, 0, 0);
      expect(isContinuousReadingGap(s, s.add(kMaxReadingGap)), isTrue);
    });

    test(
      'overnight background gap (3h) is discarded — kills phantom reading',
      () {
        // 用户报告：整夜挂起后恢复，凌晨 3/5 点被记为在读，单小时 >1h。守卫后此窗整段丢弃。
        final DateTime s = DateTime(2026, 7, 18, 3, 12, 0);
        expect(
          isContinuousReadingGap(s, s.add(const Duration(hours: 3))),
          isFalse,
        );
        expect(
          isContinuousReadingGap(
            s,
            s.add(kMaxReadingGap + const Duration(seconds: 1)),
          ),
          isFalse,
        );
      },
    );

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
        DateTime(2026, 7, 18, 9, 0, 0),
        DateTime(2026, 7, 18, 9, 0, 45),
      );
      expect(r, [('2026-07-18', 9, 45000)]);
    });

    test('crossing hour boundary → two buckets, neither exceeds its slice', () {
      final r = splitReadingTime(
        DateTime(2026, 7, 18, 9, 59, 50),
        DateTime(2026, 7, 18, 10, 0, 10),
      );
      expect(r.length, 2);
      expect(r[0], ('2026-07-18', 9, 10000));
      expect(r[1], ('2026-07-18', 10, 10000));
    });

    test('crossing midnight → two days', () {
      final r = splitReadingTime(
        DateTime(2026, 7, 18, 23, 59, 50),
        DateTime(2026, 7, 19, 0, 0, 10),
      );
      expect(r.length, 2);
      expect(r[0], ('2026-07-18', 23, 10000));
      expect(r[1], ('2026-07-19', 0, 10000));
    });

    test('zero elapsed → empty', () {
      expect(
        splitReadingTime(
          DateTime(2026, 7, 18, 9, 0, 0),
          DateTime(2026, 7, 18, 9, 0, 0),
        ),
        isEmpty,
      );
    });

    // REGRESSION（坐实根因）：撤掉 isContinuousReadingGap 守卫、直接把整段 splitReadingTime
    // 结果计入，一个小时桶会被灌进远超 3600000ms 的时长——正是「单小时 >2.5h」症状。
    test('unguarded multi-hour gap dumps >1h into a single bucket', () {
      final r = splitReadingTime(
        DateTime(2026, 7, 18, 3, 0, 0),
        DateTime(2026, 7, 18, 5, 30, 0),
      );
      // 第二个桶（5 点）拿到 2.5h，远超一小时上限——守卫存在的理由。
      final int fivePmBucketMs = r.firstWhere((e) => e.$2 == 5).$3;
      expect(fivePmBucketMs, greaterThan(3600000));
      // 但 isContinuousReadingGap 会先把这种输入挡在门外，所以生产路径 _flush 永不喂它。
      expect(
        isContinuousReadingGap(
          DateTime(2026, 7, 18, 3, 0, 0),
          DateTime(2026, 7, 18, 5, 30, 0),
        ),
        isFalse,
      );
    });
  });

  group('BUG-892 lifecycle wiring guards (reader page)', () {
    late String src;
    setUpAll(() {
      src = maskComments(
        File(
          'lib/src/pages/implementations/reader_fushi_page.dart',
        ).readAsStringSync(),
      );
    });

    test('进后台/失焦时停掉阅读时钟', () {
      final int i = src.indexOf('didChangeAppLifecycleState');
      expect(i, greaterThanOrEqualTo(0));
      final int resumed = src.indexOf('AppLifecycleState.resumed', i);
      // paused/inactive 分支（resumed 之前）里停时钟。
      final String pausedBranch = src.substring(i, resumed);
      // BUG-2209：不再直接 `_studyClock?.stop()`，改置生命周期旗 + 统一判据同步
      // （_ensureStudyClock 在后台到达时看到旗子不会把时钟重新起起来）。
      expect(
        pausedBranch.contains('_studyClockLifecycleStopped = true;'),
        isTrue,
        reason: 'BUG-892 / BUG-2209 回归：后台不置停表旗 → 挂起时长被计入 / 后台听书重启时钟',
      );
      expect(
        pausedBranch.contains('_syncStudyClockRunState();'),
        isTrue,
        reason: 'BUG-892 回归：后台不停计时 → 挂起时长被计入',
      );
    });

    test('恢复前台时重启时钟（后台段靠「时钟停着」丢弃，不靠重锚墙钟）', () {
      final int resumed = src.indexOf('AppLifecycleState.resumed');
      final String resumedBranch = src.substring(resumed, resumed + 900);
      expect(
        resumedBranch.contains('_studyClockLifecycleStopped = false;'),
        isTrue,
        reason: 'BUG-892 / BUG-2209：不清停表旗 → 回前台后时钟永远起不来',
      );
      expect(
        resumedBranch.contains('_syncStudyClockRunState();'),
        isTrue,
        reason: 'BUG-892：不重启时钟 → 回前台后阅读时长不再记账',
      );
      // BUG-1052：这里曾经是 `_sessionStartTime = DateTime.now()`。那个重锚在丢弃
      // 后台段的同时，把**重锚前那段还没落库的前台阅读时长**一并抹掉（`_flushReadingStats`
      // 以 `_sessionCharsRead <= 0` 早退时根本不消费它）。查词频繁 = 失焦/回前台频繁
      // = 几乎全部时长蒸发。现在后台段由「时钟停着不 tick」天然排除，无需重锚。
      expect(
        resumedBranch.contains('_sessionStartTime'),
        isFalse,
        reason: 'BUG-1052 回归：resumed 重锚墙钟基准会吃掉未落库的前台阅读时长',
      );
    });
  });

  // ── BUG-1052：每书/每日时长与小时桶必须共用同一个带守卫的时钟 ──────────────
  //
  // 症状（用户 2026-07-23 反馈截图）：今日 1832 字 / 时长 0 分钟 / 速度 125666 字·时⁻¹，
  // 「最快日」421249 字·时⁻¹。生产库对账坐实——同一天 reading_statistics 记 84 分钟，
  // reading_hourly_logs 记 345 分钟；两条账目差 4 倍以上，前者是错的那条。
  //
  // v92 形态：三个阅读器只剩一个 `StudyClock`（时长 / 字数 / 页数同一段、绝对值
  // 落库）——不存在第二本账可被重锚吃掉。此前「tracker.onDelta 累加进
  // `_sessionReadingMs`」「flush 前 sampleNow」那些中间形态随 `ReadingTimeTracker`
  // 一起删除，对应断言改成「这些形态一个都不许回潮」。
  group('BUG-1052 单一时钟：会话时长累计器不被任何重锚吃掉', () {
    String readMasked(String path) =>
        maskComments(File(path).readAsStringSync());

    test('三个阅读器都不再持有会话累计器 / 墙钟基准 / 逐 tick 回调', () {
      final Map<String, String> sources = <String, String>{
        'epub': readMasked(
          'lib/src/pages/implementations/reader_fushi_page.dart',
        ),
        'epub-nav': readMasked(
          'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
        ),
        'pdf': readMasked('lib/src/pages/implementations/reader_pdf_page.dart'),
        'manga': readMasked('lib/src/media/manga/reader/manga_fushi_page.dart'),
      };
      for (final MapEntry<String, String> e in sources.entries) {
        for (final String needle in <String>[
          '_sessionStartTime',
          '_sessionReadingMs',
          'onDelta:',
          'sampleNow(',
        ]) {
          expect(
            e.value.contains(needle),
            isFalse,
            reason:
                '${e.key}：`$needle` 回潮 = 第二本账重新出现，'
                '重锚 / 分账正是 BUG-1052 的形状',
          );
        }
      }
    });

    test('EPUB 字数直接记进唯一时钟的当前段', () {
      // 2026-09-06 起字数经 ReadUnitLedger（翻走即计）结算：账本在主壳构造，
      // onCredit 直接 addChars 进唯一时钟；navigation.part 的 _refreshProgress 只
      // arrive 当前可见区间。两处合起来仍是「字数与时长同一段」，没有第二本账。
      final String shell = readMasked(
        'lib/src/pages/implementations/reader_fushi_page.dart',
      );
      expect(
        shell.contains('_ensureStudyClock().addChars(readUnitsLength(fresh))'),
        isTrue,
        reason: '字数与时长必须进同一段（同 uid 一行），不得另起累计器',
      );
      final String nav = readMasked(
        'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
      );
      expect(nav.contains('_readLedger.arrive('), isTrue);
    });

    test('恢复完成（每次重排版都会跑）不得重锚会话时钟', () {
      final String nav = readMasked(
        'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
      );
      final int i = nav.indexOf('void _onRestoreComplete()');
      expect(i, greaterThanOrEqualTo(0));
      final int end = nav.indexOf('\n  void ', i + 10);
      final String body = nav.substring(i, end > i ? end : i + 4000);
      expect(
        body.contains('_sessionStartTime'),
        isFalse,
        reason: 'BUG-1052 回归：重排版/重恢复会抹掉上一段未落库的阅读时长',
      );
      // 对已在跑的时钟 start() 是 no-op：重排版不打断计时、不开新段。
      expect(
        body.contains('_ensureStudyClock();'),
        isTrue,
        reason: '恢复完成只能确保时钟在跑，不得重建 / 重锚',
      );
    });

    test('PDF 阅读器不再拿整段会话去过一次 gap 守卫', () {
      final String pdf = readMasked(
        'lib/src/pages/implementations/reader_pdf_page.dart',
      );
      expect(pdf.contains('DateTime _sessionStartTime'), isFalse);
      final int i = pdf.indexOf('Future<void> _flushReadingStats()');
      expect(i, greaterThanOrEqualTo(0));
      final String body = pdf.substring(i, math.min(i + 1400, pdf.length));
      // 旧写法：if (!isContinuousReadingGap(now - elapsed, now)) return;
      // → 任何 >120s 的正常 PDF 阅读会话被整段丢弃，读多久都记 0。
      expect(
        body.contains('isContinuousReadingGap('),
        isFalse,
        reason: 'BUG-1052 回归：整段会话过守卫 = 长会话时长恒为 0',
      );
      expect(
        body.contains('_studyClock?.flushNow()'),
        isTrue,
        reason: 'flush = 结算时钟当前窗口（gap 守卫在时钟内逐 tick 生效）',
      );
    });
  });
}
