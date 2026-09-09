import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_trends.dart'
    show kMinCphSampleMs;
import 'package:fushi/src/reader/reader_statistics_dialog.dart';
import 'package:fushi/src/reader/reader_status_footer.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, kActivityMediaBook;
import 'package:fushi_audio/fushi_audio.dart'
    show StudySessionTotals;

StatFact _fact({
  required String dateKey,
  required int chars,
  required int ms,
  String mediaKey = 'book-1',
  String title = 'Book',
}) {
  return StatFact(
    mediaKind: kActivityMediaBook,
    mediaKey: mediaKey,
    title: title,
    format: '',
    dateKey: dateKey,
    hour: -1,
    ms: ms,
    chars: chars,
    pages: 0,
    lastActiveMs: 0,
  );
}

void main() {
  group('summarizeReaderBookStats', () {
    test('按本书身份切片：今日 + 累计；legacy 无身份行按 title 回退', () {
      final DateTime now = DateTime(2026, 9, 6, 12);
      final String today = FushiDatabase.statDateKeyOf(now);
      final ReaderBookStatTotals totals = summarizeReaderBookStats(
        <StatFact>[
          _fact(dateKey: today, chars: 1000, ms: 60000),
          _fact(dateKey: '2026-09-01', chars: 5000, ms: 300000),
          // legacy：无 mediaKey，按 title 回退命中
          _fact(
            dateKey: '2026-08-30',
            chars: 700,
            ms: 42000,
            mediaKey: '',
            title: 'Book',
          ),
          // 其它书不计
          _fact(dateKey: today, chars: 999, ms: 999, mediaKey: 'other'),
        ],
        bookKey: 'book-1',
        title: 'Book',
        now: now,
      );
      expect(totals.todayChars, 1000);
      expect(totals.todayMs, 60000);
      expect(totals.allChars, 6700);
      expect(totals.allMs, 402000);
    });
  });

  group('estimateFinishMs / readerFinishCph', () {
    test('剩余字数 ÷ 速度；速度缺失返回 null，剩余 0 返回 0', () {
      expect(estimateFinishMs(remainingChars: 3600, cph: 3600), 3600000);
      expect(estimateFinishMs(remainingChars: 100, cph: null), isNull);
      expect(estimateFinishMs(remainingChars: 100, cph: 0), isNull);
      expect(estimateFinishMs(remainingChars: 0, cph: 1000), 0);
      expect(estimateFinishMs(remainingChars: null, cph: 1000), isNull);
    });

    test('会话样本够用会话速度，否则退到本书累计速度', () {
      const ReaderBookStatTotals book =
          (todayChars: 0, todayMs: 0, allChars: 6000, allMs: 3600000);
      // 会话 2 分钟 200 字 → 6000/h（样本够）
      expect(
        readerFinishCph(
          session: (durationMs: 120000, chars: 200, active: true),
          book: book,
        ),
        6000,
      );
      // 会话不足 1 分钟 → 退到累计 6000/h
      expect(
        readerFinishCph(
          session: (durationMs: 30000, chars: 50, active: true),
          book: book,
        ),
        6000,
      );
      expect(
        readerFinishCph(
          session: (durationMs: 0, chars: 0, active: false),
          book: kEmptyReaderBookStatTotals,
        ),
        isNull,
      );
    });
  });

  group('readerBookSpeedLabel（BUG-2218：今日 / 累计速度套最小样本门槛）', () {
    test('样本不足 1 分钟显示 —，与统计页 computeCph 同口径', () {
      expect(readerBookSpeedLabel(11000, 30000), '—', reason: '30 秒 1.1 万字不外推');
      expect(readerBookSpeedLabel(0, 0), '—');
      expect(readerBookSpeedLabel(100, kMinCphSampleMs - 1), '—');
    });
    test('样本够则四舍五入到整数字/时', () {
      expect(readerBookSpeedLabel(100, kMinCphSampleMs), '6000');
      expect(readerBookSpeedLabel(6000, 3600000), '6000');
      expect(readerBookSpeedLabel(1, 3600000 * 3), '0');
    });
    test('会话秒表口径不变：readingCharsPerHour 开局即 0、不设门槛', () {
      expect(readingCharsPerHour(chars: 100, durationMs: 30000), 12000);
    });
  });

  test('formatStatClock 恒带小时位', () {
    expect(formatStatClock(0), '0:00:00');
    expect(formatStatClock(41000), '0:00:41');
    expect(formatStatClock(3723000), '1:02:03');
  });

  test('readerProgressLabel 带本章括号段', () {
    expect(
      readerProgressLabel(
        current: 97694,
        total: 128006,
        chapterCurrent: 1784,
        chapterTotal: 31518,
      ),
      '97694 / 128006  76.32%  (1784 / 31518 5.66%)',
    );
    expect(
      readerProgressLabel(current: 10, total: 100),
      '10 / 100  10.00%',
    );
    expect(
      readerProgressLabel(
        current: 10,
        total: 100,
        chapterCurrent: 5,
        chapterTotal: 0,
      ),
      '10 / 100  10.00%',
    );
  });

  group('浮层排版（窄屏不截断）', () {
    /// 320dp 是仓库里最窄的在售机型宽度（见 FushiDialogFrame 的 BUG-1184 注释），
    /// 数值取到「五位字数 + 五位速度 + 带小时位的时钟」这种最长形态。
    const StudySessionTotals session = (
      durationMs: 12345678,
      chars: 98765,
      active: true,
    );

    Future<void> pumpDialog(WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReaderStatisticsDialog(
                sessionTotals: () => session,
                loadBookTotals: () async => (
                  todayChars: 87654,
                  todayMs: 23456789,
                  allChars: 987654,
                  allMs: 123456789,
                ),
                remainingChapterChars: 12345,
                remainingBookChars: 654321,
                tick: const Duration(days: 1),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // 计时 ticker 是 Timer.periodic：不卸载会留 pending timer 把测试判红。
    Future<void> disposeDialog(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox.shrink());

    testWidgets('320dp 窄屏上标签在左、数值在右，且没有一格被挤到溢出', (WidgetTester tester) async {
      await pumpDialog(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: '纯文字行不得在最窄机型上撑出 RenderFlex overflow',
      );

      // 「速度」这一行是旧三格排版最先被省略成「…」的那格（标签 + 数值 + 单位）。
      final Finder speedLabel = find.text(t.stat_metric_speed).first;
      final Finder speedRow = find
          .ancestor(of: speedLabel, matching: find.byType(Row))
          .first;
      final Rect rowRect = tester.getRect(speedRow);
      final Rect labelRect = tester.getRect(speedLabel);
      final Finder speedValue = find
          .descendant(of: speedRow, matching: find.byType(Text))
          .last;
      final Rect valueRect = tester.getRect(speedValue);

      expect(labelRect.left, lessThan(valueRect.left), reason: '左标签右数值');
      expect(
        valueRect.right,
        closeTo(rowRect.right, 0.5),
        reason: '数值贴行右缘（右对齐）',
      );
      final RenderParagraph value = tester.renderObject<RenderParagraph>(
        speedValue,
      );
      expect(value.didExceedMaxLines, isFalse, reason: '数值整条行宽可用，不再被省略成「…」');
      await disposeDialog(tester);
    });

    testWidgets('浮层里不再有手动计时开关：看统计期间计时本来就停着', (WidgetTester tester) async {
      await pumpDialog(tester);
      expect(
        find.byKey(
          const ValueKey<String>('fushi_reader_stats_tracking_toggle'),
        ),
        findsNothing,
        reason: '开浮层经 _withStudyClockPaused 停表（BUG-2208），层内开关改不动运行态',
      );
      expect(find.text(t.pause), findsNothing);
      expect(find.text(t.play), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      await disposeDialog(tester);
    });
  });
}
