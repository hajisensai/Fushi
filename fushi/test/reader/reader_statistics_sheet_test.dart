import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
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

    test('近 7 天逐日序列：恰 7 项升序、末项今天、断读补 0、窗口外与其它书不计', () {
      final DateTime now = DateTime(2026, 9, 6, 12);
      final String today = FushiDatabase.statDateKeyOf(now);
      final String twoDaysAgo = FushiDatabase.statDateKeyPlusDays(today, -2);
      final String eightDaysAgo = FushiDatabase.statDateKeyPlusDays(today, -8);
      final ReaderBookStatTotals totals = summarizeReaderBookStats(
        <StatFact>[
          _fact(dateKey: today, chars: 1000, ms: 60000),
          // 同一天两条事实（不同格式 / 会话）累加进同一根柱子。
          _fact(dateKey: twoDaysAgo, chars: 300, ms: 20000),
          _fact(dateKey: twoDaysAgo, chars: 200, ms: 10000),
          // 窗口外：进累计不进 7 天序列。
          _fact(dateKey: eightDaysAgo, chars: 5000, ms: 300000),
          // 其它书：哪里都不计。
          _fact(dateKey: today, chars: 999, ms: 999, mediaKey: 'other'),
        ],
        bookKey: 'book-1',
        title: 'Book',
        now: now,
      );
      final List<ReaderBookDayStat> week = totals.last7Days;
      expect(week, hasLength(7));
      expect(week.last.dateKey, today);
      expect(week.first.dateKey, FushiDatabase.statDateKeyPlusDays(today, -6));
      for (int i = 1; i < week.length; i++) {
        expect(week[i].dateKey.compareTo(week[i - 1].dateKey), greaterThan(0));
      }
      expect(week.last.chars, 1000);
      expect(week[4].dateKey, twoDaysAgo);
      expect(week[4].chars, 500);
      expect(week[4].ms, 30000);
      expect(
        week.fold<int>(0, (int a, ReaderBookDayStat d) => a + d.chars),
        1500,
      );
      expect(totals.allChars, 6500);
      expect(kEmptyReaderBookStatTotals.last7Days, isEmpty);
    });
  });

  test('指标卡列数：侧栏 / 窄底板 2 列，宽底板且指标多于 2 个才 4 列', () {
    expect(readerStatMetricColumns(400, 4), 2);
    expect(readerStatMetricColumns(360, 4), 2);
    expect(readerStatMetricColumns(519, 4), 2);
    expect(readerStatMetricColumns(560, 4), 4);
    expect(readerStatMetricColumns(560, 2), 2);
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
        last7Days: <ReaderBookDayStat>[],
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
      last7Days: <ReaderBookDayStat>[
        (dateKey: '2026-09-30', chars: 0, ms: 0),
        (dateKey: '2026-10-01', chars: 4200, ms: 900000),
        (dateKey: '2026-10-02', chars: 0, ms: 0),
        (dateKey: '2026-10-03', chars: 8800, ms: 1800000),
        (dateKey: '2026-10-04', chars: 3100, ms: 700000),
        (dateKey: '2026-10-05', chars: 6400, ms: 1200000),
        (dateKey: '2026-10-06', chars: 12640, ms: 1440000),
      ],
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
      // MD3 Expressive 波浪进度条确定态也持续流动（repeat ticker），
      // pumpAndSettle 永不收敛：先让 loadBookTotals 落地，再推过 250ms 的值补间。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
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
      // 今天：四张指标卡，查词 / 制卡来自 per-book 计数面。
      String valueOf(String key) =>
          tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;
      expect(valueOf('fushi_reader_stats_today_chars'), '12,640');
      expect(valueOf('fushi_reader_stats_today_lookups'), '83');
      expect(valueOf('fushi_reader_stats_today_cards'), '12');
      expect(find.text(t.stat_lookup), findsOneWidget);
      expect(find.text(t.stat_mined), findsOneWidget);
      // 本书累计字数千分位。
      expect(valueOf('fushi_reader_stats_all_chars'), '62,140');
      // 近 7 天迷你柱状图有数据时画图表，不出空态。
      expect(
        find.byKey(const ValueKey<String>('fushi_reader_stats_week_chart')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('fushi_reader_stats_week_empty')),
        findsNothing,
      );
      // 本次阅读 hero：会话字数作副指标。
      expect(find.text(t.reader_stats_session_title), findsOneWidget);
      expect(find.text(t.stat_format_chars(n: '12,640')), findsOneWidget);
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
      // 指标卡 + 近 7 天图表之后「打开完整记录」在首屏之下，先滚进视口。
      final Finder full = find.byKey(
        const ValueKey<String>('fushi_reader_stats_full'),
      );
      await tester.ensureVisible(full);
      await tester.pump();
      await tester.tap(full);
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

    for (final double width in <double>[320, 400, 420, 600]) {
      testWidgets('宽 $width 不溢出（窄底板 / 右侧栏 / 宽底板）', (
        WidgetTester tester,
      ) async {
        await pumpSheet(tester, width: width);
        expect(tester.takeException(), isNull);
        await disposeSheet(tester);
      });
    }

    testWidgets('宽底板指标卡一行 4 列，侧栏宽 2 列', (WidgetTester tester) async {
      double rowOf(String key) =>
          tester.getTopLeft(find.byKey(ValueKey<String>(key))).dy;
      await pumpSheet(tester, width: 600);
      expect(
        rowOf('fushi_reader_stats_today_time'),
        rowOf('fushi_reader_stats_today_cards'),
      );
      await disposeSheet(tester);
      await pumpSheet(tester, width: 400);
      expect(
        rowOf('fushi_reader_stats_today_time'),
        rowOf('fushi_reader_stats_today_chars'),
      );
      expect(
        rowOf('fushi_reader_stats_today_lookups'),
        greaterThan(rowOf('fushi_reader_stats_today_time')),
      );
      await disposeSheet(tester);
    });

    testWidgets('暂停键与「打开完整记录」可被 Tab 焦点遍历到', (WidgetTester tester) async {
      await pumpSheet(tester);
      const ValueKey<String> pauseKey = ValueKey<String>(
        'fushi_reader_stats_pause',
      );
      const ValueKey<String> fullKey = ValueKey<String>(
        'fushi_reader_stats_full',
      );
      final Set<Key> reached = <Key>{};
      for (int i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final BuildContext? focused =
            FocusManager.instance.primaryFocus?.context;
        if (focused == null) continue;
        focused.visitAncestorElements((Element e) {
          final Key? k = e.widget.key;
          if (k == pauseKey || k == fullKey) {
            reached.add(k!);
            return false;
          }
          return true;
        });
      }
      expect(reached, containsAll(<Key>[pauseKey, fullKey]));
      await disposeSheet(tester);
    });

    testWidgets('本书近 7 天无阅读时显示空态而不是空图表', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderStatisticsSheet(
              bookTitle: '',
              sessionTotals: () => session,
              loadBookTotals: () async => kEmptyReaderBookStatTotals,
              progress: () => (
                chapterCurrent: null,
                chapterTotal: null,
                bookCurrent: null,
                bookTotal: null,
              ),
              onTogglePause: () {},
              onOpenFullRecords: () {},
              tick: const Duration(days: 1),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey<String>('fushi_reader_stats_week_empty')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await disposeSheet(tester);
    });
  });
}
