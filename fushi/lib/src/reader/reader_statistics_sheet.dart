/// 阅读器内「书内统计」右侧侧栏。
///
/// 由 `_openReadingStatistics` 经 `showReaderSideSheet` 从右贴边滑出（与导航 /
/// 设置 / 有声书同一容器，用户 2026-09-13 拍板：不再弹居中对话框）。自上而下：
///
///  1. 标题「书内统计」+ 书名；
///  2. 大号实时秒表 + 计时态点 + 暂停 / 继续键（[onTogglePause]，与状态行计时块
///     同一入口 `_toggleStudyClockManualPause`）；本次字数 / 字时；
///  3. 阅读位置：本章 / 全书 `已读 / 总字数` + 进度条 + 百分比（读口
///     [ReaderStatisticsSheet.progress]，与状态行同源）；
///  4. 今天（本书）：时长 / 字数 / 查词 / 制卡；
///  5. 本书累计：时长 / 字数；
///  6. 预计读完：本章还需 / 全书还需（剩余字数 ÷ 速度，[readerFinishCph]）；
///  7. 「打开完整记录 →」跳统计中心阅读 tab。
///
/// 账本只在 `StudyClock` 一本，本层不持有任何会话累计副本——会话读数是每秒采样
/// 的函数（同底部状态行）。今日 / 累计按**本书**身份从统一事实面 `loadStatFacts`
/// 切片（统计域 v92 纪律：展示只从 `StatFacts` 派生）。
///
/// 侧栏**不停表**：它不遮正文，正文照常可读；此前的居中对话框经
/// `_withStudyClockPaused` 停表（BUG-2208），那条纪律只对压着正文的弹层成立。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudySessionTotals;
import 'package:fushi_core/fushi_core.dart' show LookupMiningCounterRow;

import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatTime;
import 'package:fushi/src/pages/implementations/stat_trends.dart'
    show computeCph, kMinCphSampleMs;
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show ReaderSideSheetSectionLabel;
import 'package:fushi/src/reader/reader_status_footer.dart'
    show readerProgressRatio, readingCharsPerHour;
import 'package:fushi_engine/stats/stat_facts.dart'
    show StatFact, statFactBelongsToBook;
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/utils.dart';

/// 本书的今日 / 累计阅读量（字数 + 毫秒）+ 今日查词 / 制卡数。
typedef ReaderBookStatTotals = ({
  int todayChars,
  int todayMs,
  int todayLookups,
  int todayCards,
  int allChars,
  int allMs,
});

const ReaderBookStatTotals kEmptyReaderBookStatTotals = (
  todayChars: 0,
  todayMs: 0,
  todayLookups: 0,
  todayCards: 0,
  allChars: 0,
  allMs: 0,
);

/// 阅读位置读口：本章 / 全书的已读与总字数（任一未知为 null）。
typedef ReaderPositionSnapshot = ({
  int? chapterCurrent,
  int? chapterTotal,
  int? bookCurrent,
  int? bookTotal,
});

/// 从阅读域日面事实里切出**本书**的今日 / 累计。身份优先 `mediaKey == bookKey`；
/// legacy 无身份行按 title 回退（与阅读统计页的按书分组同一规则）。
///
/// [counters] 是 per-book 查词 / 制卡计数面（`lookup_mining_counters`），只取今日；
/// 身份优先 `bookKey`，`bookKey` 为空的旧行（该列是后补的 `withDefault('')`）按
/// title 回退——与 [dailyBooks] 同一口径。
ReaderBookStatTotals summarizeReaderBookStats(
  Iterable<StatFact> dailyBooks, {
  Iterable<LookupMiningCounterRow> counters = const <LookupMiningCounterRow>[],
  required String bookKey,
  required String? title,
  required DateTime now,
}) {
  final StatWindow window = StatWindow(now);
  int todayChars = 0;
  int todayMs = 0;
  int allChars = 0;
  int allMs = 0;
  for (final StatFact f in dailyBooks) {
    if (!statFactBelongsToBook(f, bookKey: bookKey, title: title)) continue;
    allChars += f.chars;
    allMs += f.ms;
    if (window.isToday(f.dateKey)) {
      todayChars += f.chars;
      todayMs += f.ms;
    }
  }
  int todayLookups = 0;
  int todayCards = 0;
  for (final LookupMiningCounterRow c in counters) {
    final bool mine = c.bookKey.isNotEmpty
        ? c.bookKey == bookKey
        : (title != null && title.isNotEmpty && c.title == title);
    if (!mine || !window.isToday(c.dateKey)) continue;
    todayLookups += c.lookupCount;
    todayCards += c.mineCount;
  }
  return (
    todayChars: todayChars,
    todayMs: todayMs,
    todayLookups: todayLookups,
    todayCards: todayCards,
    allChars: allChars,
    allMs: allMs,
  );
}

/// 预计读完所需毫秒：剩余字数 ÷ 速度（字/时）。速度 ≤ 0 或剩余未知时 null。
int? estimateFinishMs({required int? remainingChars, required double? cph}) {
  if (remainingChars == null || cph == null || cph <= 0) return null;
  if (remainingChars <= 0) return 0;
  return (remainingChars / cph * 3600000).round();
}

/// 预计读完用的速度：本次会话样本够（≥ 1 分钟且有字数）用会话速度，否则退到本书
/// 累计速度；都没有 → null（显示「—」）。
double? readerFinishCph({
  required StudySessionTotals session,
  required ReaderBookStatTotals book,
}) {
  final double? sessionCph =
      session.chars > 0 ? computeCph(session.chars, session.durationMs) : null;
  if (sessionCph != null && sessionCph > 0) return sessionCph;
  final double? allCph = computeCph(book.allChars, book.allMs);
  return (allCph != null && allCph > 0) ? allCph : null;
}

/// 今日 / 累计卡的速度文案（BUG-2218）：与统计页同一口径 [computeCph]（最小样本
/// [kMinCphSampleMs]），样本不足显示与统计页一致的 `—`，不再把几十秒的脏样本外推成
/// 爆表数字。会话卡是实时秒表，仍走 [readingCharsPerHour] 开局即显 `0`。
String readerBookSpeedLabel(int chars, int ms) {
  final double? cph = computeCph(chars, ms);
  return cph == null ? '—' : '${cph.round()}';
}

/// `h:mm:ss`（恒带小时位，与 Hoshi 一致）。
String formatStatClock(int ms) {
  final int total = ms <= 0 ? 0 : ms ~/ 1000;
  final int h = total ~/ 3600;
  final int m = (total % 3600) ~/ 60;
  final int s = total % 60;
  return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// 千分位整数（`12,640`）。统计侧栏里的字数都走这里，与样稿一致；不引入 intl
/// 的 locale 分隔符差异——阅读面读数用固定逗号。
String formatGroupedInt(int n) {
  final String digits = n.abs().toString();
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return n < 0 ? '-$out' : out.toString();
}

/// 剩余字数：总数 − 已读，任一未知 → null。
int? readerRemainingChars({required int? current, required int? total}) {
  if (current == null || total == null) return null;
  return (total - current).clamp(0, total);
}

class ReaderStatisticsSheet extends StatefulWidget {
  const ReaderStatisticsSheet({
    super.key,
    required this.bookTitle,
    required this.sessionTotals,
    required this.loadBookTotals,
    required this.progress,
    required this.onTogglePause,
    required this.onOpenFullRecords,
    this.tick = const Duration(seconds: 1),
  });

  final String bookTitle;

  /// 会话累计读口（每 [tick] 采样一次，账本在 StudyClock）。
  final StudySessionTotals Function() sessionTotals;

  /// 本书今日 / 累计（从统一事实面加载，进侧栏时读一次）。
  final Future<ReaderBookStatTotals> Function() loadBookTotals;

  /// 阅读位置读口（每 [tick] 采样，翻页后侧栏里的进度跟着走）。
  final ReaderPositionSnapshot Function() progress;

  /// 暂停 / 继续手动计时（与状态行计时块同一入口）。
  final VoidCallback onTogglePause;

  /// 「打开完整记录」→ 统计中心。
  final VoidCallback onOpenFullRecords;

  final Duration tick;

  @override
  State<ReaderStatisticsSheet> createState() => _ReaderStatisticsSheetState();
}

class _ReaderStatisticsSheetState extends State<ReaderStatisticsSheet> {
  Timer? _ticker;
  ReaderBookStatTotals? _book;
  Object? _lastSnapshot;

  @override
  void initState() {
    super.initState();
    // 会话 / 位置读数按秒采样，但只在秒 / 字数 / 计时态 / 位置变了才重建
    // （暂停且不翻页时零重建）。
    _ticker = Timer.periodic(widget.tick, (_) {
      if (!mounted) return;
      final StudySessionTotals s = widget.sessionTotals();
      final ReaderPositionSnapshot p = widget.progress();
      final Object snap = (
        seconds: s.durationMs ~/ 1000,
        chars: s.chars,
        active: s.active,
        chapter: p.chapterCurrent,
        book: p.bookCurrent,
      );
      if (snap == _lastSnapshot) return;
      setState(() => _lastSnapshot = snap);
    });
    unawaited(
      widget.loadBookTotals().then((ReaderBookStatTotals totals) {
        if (mounted) setState(() => _book = totals);
      }),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final StudySessionTotals session = widget.sessionTotals();
    final ReaderBookStatTotals book = _book ?? kEmptyReaderBookStatTotals;
    final ReaderPositionSnapshot pos = widget.progress();
    final double? finishCph = readerFinishCph(session: session, book: book);
    final int? chapterMs = estimateFinishMs(
      remainingChars: readerRemainingChars(
        current: pos.chapterCurrent,
        total: pos.chapterTotal,
      ),
      cph: finishCph,
    );
    final int? bookMs = estimateFinishMs(
      remainingChars: readerRemainingChars(
        current: pos.bookCurrent,
        total: pos.bookTotal,
      ),
      cph: finishCph,
    );
    final TextStyle muted = theme.textTheme.bodyMedium!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t.reader_stats_title,
                      key: const ValueKey<String>('fushi_side_sheet_title'),
                      style: theme.textTheme.titleLarge,
                    ),
                    if (widget.bookTitle.trim().isNotEmpty)
                      Text(
                        widget.bookTitle,
                        style: muted,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              Semantics(
                identifier: 'hibiki.reader.side_sheet.close',
                child: IconButton(
                  key: const ValueKey<String>('fushi_reader_stats_close'),
                  icon: const Icon(Icons.close),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(height: tokens.spacing.gap),
                _SessionClock(
                  session: session,
                  onTogglePause: widget.onTogglePause,
                ),
                SizedBox(height: tokens.spacing.gap),
                _InlineMetrics(
                  cells: <String>[
                    '${t.reader_stats_session}  '
                        '${t.stat_format_chars(n: formatGroupedInt(session.chars))}',
                    t.reader_stats_chars_per_hour(
                      n: formatGroupedInt(
                        readingCharsPerHour(
                          chars: session.chars,
                          durationMs: session.durationMs,
                        ),
                      ),
                    ),
                  ],
                ),
                const _Rule(),
                ReaderSideSheetSectionLabel(t.reader_stats_position),
                _PositionRow(
                  label: t.reader_stats_position_chapter,
                  current: pos.chapterCurrent,
                  total: pos.chapterTotal,
                  keyPrefix: 'chapter',
                ),
                SizedBox(height: tokens.spacing.gap),
                _PositionRow(
                  label: t.reader_stats_position_book,
                  current: pos.bookCurrent,
                  total: pos.bookTotal,
                  keyPrefix: 'book',
                ),
                const _Rule(),
                ReaderSideSheetSectionLabel(t.stat_today),
                _InlineMetrics(
                  key: const ValueKey<String>('fushi_reader_stats_today'),
                  cells: <String>[
                    formatStatTime(book.todayMs),
                    t.stat_format_chars(n: formatGroupedInt(book.todayChars)),
                    t.reader_stats_lookups(n: '${book.todayLookups}'),
                    t.reader_stats_cards(n: '${book.todayCards}'),
                  ],
                ),
                const _Rule(),
                ReaderSideSheetSectionLabel(t.reader_stats_book_total),
                _InlineMetrics(
                  key: const ValueKey<String>('fushi_reader_stats_all'),
                  cells: <String>[
                    formatStatTime(book.allMs),
                    t.stat_format_chars(n: formatGroupedInt(book.allChars)),
                  ],
                ),
                const _Rule(),
                ReaderSideSheetSectionLabel(t.reader_stats_time_to_finish),
                _LabelValueRow(
                  label: t.reader_stats_remaining_chapter,
                  value: chapterMs == null ? '—' : formatStatTime(chapterMs),
                  valueKey: 'fushi_reader_stats_finish_chapter',
                ),
                SizedBox(height: tokens.spacing.gap / 2),
                _LabelValueRow(
                  label: t.reader_stats_remaining_book,
                  value: bookMs == null ? '—' : formatStatTime(bookMs),
                  valueKey: 'fushi_reader_stats_finish_book',
                ),
                SizedBox(height: tokens.spacing.gap * 2),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    key: const ValueKey<String>('fushi_reader_stats_full'),
                    onPressed: widget.onOpenFullRecords,
                    icon: const Icon(Icons.chevron_right, size: 18),
                    iconAlignment: IconAlignment.end,
                    label: Text(t.reader_stats_full_records_open),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 大号实时秒表 + 计时态 + 暂停 / 继续键。
class _SessionClock extends StatelessWidget {
  const _SessionClock({required this.session, required this.onTogglePause});

  final StudySessionTotals session;
  final VoidCallback onTogglePause;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color dot =
        session.active ? theme.colorScheme.primary : theme.colorScheme.outline;
    return Row(
      children: <Widget>[
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 12,
            children: <Widget>[
              Text(
                formatStatClock(session.durationMs),
                key: const ValueKey<String>('fushi_reader_stats_clock'),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: dot,
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox(width: 8, height: 8),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      session.active
                          ? t.reader_stats_clock_running
                          : t.reader_stats_clock_paused,
                      key: const ValueKey<String>('fushi_reader_stats_state'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Semantics(
          identifier: 'hibiki.reader.stats.toggle_pause',
          child: IconButton.outlined(
            key: const ValueKey<String>('fushi_reader_stats_pause'),
            icon: Icon(
              session.active ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
            tooltip: session.active
                ? t.reader_stats_clock_pause
                : t.reader_stats_clock_resume,
            onPressed: onTogglePause,
          ),
        ),
      ],
    );
  }
}

/// 一行内以细竖线分隔的几段读数（`24 分钟 | 12,640 字 | 查词 83 | 制卡 12`）。
/// 段之间可换行：窄侧栏里四段放不下时自然折到第二行，不省略任何数字。
class _InlineMetrics extends StatelessWidget {
  const _InlineMetrics({super.key, required this.cells});

  final List<String> cells;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle style = theme.textTheme.titleMedium!.copyWith(
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return Wrap(
      spacing: 0,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        for (int i = 0; i < cells.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (i > 0)
                Container(
                  width: 1,
                  height: 16,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  color: theme.colorScheme.outlineVariant,
                ),
              // Row 给非弹性子项的是无界宽：长文案必须包 Flexible 才会折行而不是
              // 撑出行外（Wrap 只负责段与段之间换行）。
              Flexible(child: Text(cells[i], style: style)),
            ],
          ),
      ],
    );
  }
}

/// 阅读位置一行：`本章  1,842 / 4,930 字` + 进度条 + `37%`。
class _PositionRow extends StatelessWidget {
  const _PositionRow({
    required this.label,
    required this.current,
    required this.total,
    required this.keyPrefix,
  });

  final String label;
  final int? current;
  final int? total;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double? ratio = readerProgressRatio(current: current, total: total);
    final TextStyle labelStyle = theme.textTheme.bodyMedium!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final TextStyle valueStyle = theme.textTheme.bodyMedium!.copyWith(
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(label, style: labelStyle),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                ratio == null
                    ? '—'
                    : t.reader_stats_position_progress(
                        current: formatGroupedInt(current!),
                        total: formatGroupedInt(total!),
                      ),
                key: ValueKey<String>('fushi_reader_stats_${keyPrefix}_text'),
                style: valueStyle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  key: ValueKey<String>('fushi_reader_stats_${keyPrefix}_bar'),
                  value: ratio ?? 0,
                  minHeight: 6,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 44,
              child: Text(
                ratio == null ? '—' : '${(ratio * 100).round()}%',
                key: ValueKey<String>('fushi_reader_stats_${keyPrefix}_pct'),
                style: valueStyle,
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _LabelValueRow extends StatelessWidget {
  const _LabelValueRow({
    required this.label,
    required this.value,
    required this.valueKey,
  });

  final String label;
  final String value;
  final String valueKey;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Container(
          width: 1,
          height: 16,
          margin: const EdgeInsets.symmetric(horizontal: 12),
          color: theme.colorScheme.outlineVariant,
        ),
        Expanded(
          child: Text(
            value,
            key: ValueKey<String>(valueKey),
            style: theme.textTheme.titleMedium!.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Divider(
        height: 1,
        thickness: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}
