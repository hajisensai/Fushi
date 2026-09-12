import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_trends.dart'
    show kMinCphSampleMs;
import 'package:fushi/src/reader/reader_statistics_sheet.dart';
import 'package:fushi/src/reader/reader_status_footer.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, LookupMiningCounterRow, kActivityMediaBook;
import 'package:fushi_audio/fushi_audio.dart' show StudySessionTotals;

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

LookupMiningCounterRow _counter({
  required String dateKey,
  required int lookups,
  required int mines,
  String bookKey = 'book-1',
}) =>
    LookupMiningCounterRow(
      id: 0,
      bookKey: bookKey,
      title: 'Book',
      sourceType: 'reader',
      dateKey: dateKey,
      lookupCount: lookups,
      mineCount: mines,
    );

void main() {
  group('summarizeReaderBookStats', () {
    test('按本书身份切片：今日 + 累计 + 今日查词/制卡；legacy 无身份行按 title 回退', () {
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
        counters: <LookupMiningCounterRow>[
          _counter(dateKey: today, lookups: 83, mines: 12),
          // 昨天 / 其它书都不进「今天」
          _counter(dateKey: '2026-09-05', lookups: 5, mines: 1),
          _counter(dateKey: today, lookups: 7, mines: 7, bookKey: 'other'),
          // legacy：bookKey 为空，按 title 回退命中
          _counter(dateKey: today, lookups: 2, mines: 1, bookKey: ''),
        ],
        bookKey: 'book-1',
        title: 'Book',
        now: now,
      );
      expect(totals.todayChars, 1000);
      expect(totals.todayMs, 60000);
      expect(totals.todayLookups, 85);
      expect(totals.todayCards, 13);
      expect(totals.allChars, 6700);
      expect(totals.allMs, 402000);
    });
  });

  group('estimateFinishMs / readerFinishCph / readerRemainingChars', () {
    test('剩余字数 ÷ 速度；速度缺失返回 null，剩余 0 返回 0', () {
      expect(estimateFinishMs(remainingChars: 3600, cph: 3600), 3600000);
      expect(estimateFinishMs(remainingChars: 100, cph: null), isNull);
      expect(estimateFinishMs(remainingChars: 100, cph: 0), isNull);
      expect(estimateFinishMs(remainingChars: 0, cph: 1000), 0);
      expect(estimateFinishMs(remainingChars: null, cph: 1000), isNull);
    });

    test('剩余字数 = 总数 − 已读，钳到 [0, total]；未知为 null', () {
      expect(readerRemainingChars(current: 30, total: 100), 70);
      expect(readerRemainingChars(current: 120, total: 100), 0);
      expect(readerRemainingChars(current: null, total: 100), isNull);
      expect(readerRemainingChars(current: 1, total: null), isNull);
    });

    test('会话样本够用会话速度，否则退到本书累计速度', () {
      const ReaderBookStatTotals book = (
        todayChars: 0,
        todayMs: 0,
        todayLookups: 0,
        todayCards: 0,
        allChars: 6000,
        allMs: 3600000,
      );
      expect(
        readerFinishCph(
          session: (durationMs: 120000, chars: 200, active: true),
          book: book,
        ),
        6000,
      );
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
      expect(readerBookSpeedLabel(11000, 30000), '—');
      expect(readerBookSpeedLabel(0, 0), '—');
      expect(readerBookSpeedLabel(100, kMinCphSampleMs - 1), '—');
    });
    test('样本够则四舍五入到整数字/时', () {
      expect(readerBookSpeedLabel(100, kMinCphSampleMs), '6000');
      expect(readerBookSpeedLabel(6000, 3600000), '6000');
    });
    test('会话秒表口径不变：readingCharsPerHour 开局即 0、不设门槛', () {
      expect(readingCharsPerHour(chars: 100, durationMs: 30000), 12000);
    });
  });

  test('formatStatClock 恒带小时位；formatGroupedInt 千分位', () {
    expect(formatStatClock(0), '0:00:00');
    expect(formatStatClock(41000), '0:00:41');
    expect(formatStatClock(3723000), '1:02:03');
    expect(formatGroupedInt(0), '0');
    expect(formatGroupedInt(999), '999');
    expect(formatGroupedInt(1000), '1,000');
    expect(formatGroupedInt(12640), '12,640');
    expect(formatGroupedInt(86420), '86,420');
    expect(formatGroupedInt(1234567), '1,234,567');
  });

  group('ReaderStatisticsSheet', () {
    const StudySessionTotals session = (
      durationMs: 1458000, // 0:24:18
      chars: 12640,
      active: true,
    );
    const ReaderBookStatTotals book = (
      todayChars: 12640,
      todayMs: 1440000,
      todayLookups: 83,
      todayCards: 12,
      allChars: 62140,
      allMs: 29640000,
    );

    Future<void> pumpSheet(
      WidgetTester tester, {
      double width = 400,
      VoidCallback? onTogglePause,
      VoidCallback? onOpenFullRecords,
      StudySessionTotals Function()? sessionTotals,
    }) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderStatisticsSheet(
              bookTitle: '春の手紙',
              sessionTotals: sessionTotals ?? () => session,
              loadBookTotals: () async => book,
              progress: () => (
                chapterCurrent: 1842,
                chapterTotal: 4930,
                bookCurrent: 24680,
                bookTotal: 86420,
              ),
              onTogglePause: onTogglePause ?? () {},
              onOpenFullRecords: onOpenFullRecords ?? () {},
              tick: const Duration(days: 1),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // 计时 ticker 是 Timer.periodic：不卸载会留 pending timer 把测试判红。
    Future<void> disposeSheet(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox.shrink());

    testWidgets('样稿六块齐全：秒表 / 位置进度条 / 今天 / 累计 / 预计读完 / 完整记录', (
      WidgetTester tester,
    ) async {
      await pumpSheet(tester);
      expect(tester.takeException(), isNull);
      expect(find.text(t.reader_stats_title), findsOneWidget);
      expect(find.text('春の手紙'), findsOneWidget);
      expect(find.text('0:24:18'), findsOneWidget);
      expect(find.text(t.reader_stats_clock_running), findsOneWidget);
      // 阅读位置两条进度条 + 百分比（37% / 29%）。
      expect(
        find.byKey(const ValueKey<String>('fushi_reader_stats_chapter_bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('fushi_reader_stats_book_bar')),
        findsOneWidget,
      );
      expect(find.text('37%'), findsOneWidget);
      expect(find.text('29%'), findsOneWidget);
      expect(
        find.text(
          t.reader_stats_position_progress(current: '1,842', total: '4,930'),
        ),
        findsOneWidget,
      );
      // 今天：查词 / 制卡来自 per-book 计数面。
      expect(find.text(t.reader_stats_lookups(n: '83')), findsOneWidget);
      expect(find.text(t.reader_stats_cards(n: '12')), findsOneWidget);
      // 本书累计字数千分位。
      expect(find.text(t.stat_format_chars(n: '62,140')), findsOneWidget);
      // 预计读完两行有值（会话 12640 字 / 24 分 → 速度够）。
      final Text chapterLeft = tester.widget(
        find.byKey(const ValueKey<String>('fushi_reader_stats_finish_chapter')),
      );
      expect(chapterLeft.data, isNot('—'));
      expect(
        find.byKey(const ValueKey<String>('fushi_reader_stats_full')),
        findsOneWidget,
      );
      await disposeSheet(tester);
    });

    testWidgets('暂停键与「打开完整记录」接到回调；暂停态换图标与文案', (WidgetTester tester) async {
      int pauses = 0;
      int opens = 0;
      bool active = true;
      await pumpSheet(
        tester,
        onTogglePause: () => pauses++,
        onOpenFullRecords: () => opens++,
        sessionTotals: () => (
          durationMs: session.durationMs,
          chars: session.chars,
          active: active,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('fushi_reader_stats_pause')),
      );
      expect(pauses, 1);
      await tester.tap(
        find.byKey(const ValueKey<String>('fushi_reader_stats_full')),
      );
      expect(opens, 1);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      active = false;
      await pumpSheet(
        tester,
        onTogglePause: () => pauses++,
        sessionTotals: () => (
          durationMs: session.durationMs,
          chars: session.chars,
          active: active,
        ),
      );
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text(t.reader_stats_clock_paused), findsOneWidget);
      await disposeSheet(tester);
    });

    testWidgets('320dp 窄侧栏不溢出', (WidgetTester tester) async {
      await pumpSheet(tester, width: 320);
      expect(tester.takeException(), isNull);
      await disposeSheet(tester);
    });
  });
}
