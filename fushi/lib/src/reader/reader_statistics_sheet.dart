/// 阅读器内「书内统计」右侧侧栏。
///
/// 由 `_openReadingStatistics` 经 `showReaderSideSheet` 从右贴边滑出（与导航 /
/// 设置 / 有声书同一容器，用户 2026-09-13 拍板：不再弹居中对话框）。自上而下：
///
///  1. 标题「书内统计」+ 书名；
///  2. 「本次阅读」hero 卡（2026-10 M3 Expressive 重设计）：大号实时秒表 + 计时态 +
///     暂停 / 继续键（[onTogglePause]，与状态行计时块同一入口
///     `_toggleStudyClockManualPause`）；本次字数 / 字时；
///  3. 阅读位置卡：本章 / 全书 `已读 / 总字数` + 百分比 + 进度条（读口
///     [ReaderStatisticsSheet.progress]，与状态行同源）；
///  4. 今天（本书）指标卡：时长 / 字数 / 查词 / 制卡；
///  5. 近 7 天迷你柱状图（本书每日字数，复用统计中心 [StatBarChartPainter]）；
///  6. 本书累计指标卡：时长 / 字数；
///  7. 预计读完指标卡：本章还需 / 全书还需（剩余字数 ÷ 速度，[readerFinishCph]）；
///  8. 「打开完整记录 →」跳统计中心阅读 tab。
///
/// 指标卡网格按可用宽度自适应列数（[readerStatMetricColumns]：右侧栏 400 / 窄屏
/// 底板 2 列，宽底板 4 列）；各块在 [FushiEntranceScope] 内错峰进场。
///
/// 视觉（2026-10 统一面板语言）：卡片 / 大数字 / 进度 / 分组标题全部取
/// `reader_panel_kit.dart`——hero 是 primaryContainer 饱和色块、阅读位置与预计
/// 读完是 tertiary 分区、其余中性卡；时长 / 字数 / 字时 / 百分比用
/// [ReaderStatNumber] Display 级数字；进度走 [ReaderPanelProgress]（M3E 波浪 /
/// Apple 细线）；暂停键在 M3E 下圆角方 ↔ 圆形状变形。Apple 保持分组卡语汇。
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
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudySessionTotals;
import 'package:fushi_core/fushi_core.dart' show LookupMiningCounterRow;

import 'package:fushi/src/pages/implementations/reader_fushi/reader_panel_kit.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart'
    show StatBarChartPainter, StatDayData;
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show StatChartEntrance, formatStatTime;
import 'package:fushi/src/pages/implementations/stat_trends.dart'
    show computeCph, kMinCphSampleMs;
import 'package:fushi/src/reader/reader_status_footer.dart'
    show readerProgressRatio, readingCharsPerHour;
import 'package:fushi_engine/stats/stat_facts.dart'
    show StatFact, statFactBelongsToBook;
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/utils.dart';

/// 本书某个统计日的阅读量（迷你柱状图的一根柱子）。
typedef ReaderBookDayStat = ({String dateKey, int chars, int ms});

/// 本书的今日 / 累计阅读量（字数 + 毫秒）+ 今日查词 / 制卡数 + 近 7 天逐日序列。
///
/// [last7Days] 恰 7 项、按日期升序、末项是今天（[StatWindow.lastDayKeys]），没读
/// 的日子补 0——图表横轴不会因为断读而少柱。空态（[kEmptyReaderBookStatTotals]）
/// 为空表，表示「还没加载」。
typedef ReaderBookStatTotals = ({
  int todayChars,
  int todayMs,
  int todayLookups,
  int todayCards,
  int allChars,
  int allMs,
  List<ReaderBookDayStat> last7Days,
});

const ReaderBookStatTotals kEmptyReaderBookStatTotals = (
  todayChars: 0,
  todayMs: 0,
  todayLookups: 0,
  todayCards: 0,
  allChars: 0,
  allMs: 0,
  last7Days: <ReaderBookDayStat>[],
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
  // 近 7 天逐日累加：与「今日」同一个 [StatWindow]（同一锚时刻、同一统计日边界），
  // 跨午夜打开侧栏时柱子与今日卡不会落在两个时刻上（BUG-2219 同款纪律）。
  final List<String> weekKeys = window.lastDayKeys(7);
  final Map<String, ({int chars, int ms})> week =
      <String, ({int chars, int ms})>{
    for (final String key in weekKeys) key: (chars: 0, ms: 0),
  };
  for (final StatFact f in dailyBooks) {
    if (!statFactBelongsToBook(f, bookKey: bookKey, title: title)) continue;
    allChars += f.chars;
    allMs += f.ms;
    if (window.isToday(f.dateKey)) {
      todayChars += f.chars;
      todayMs += f.ms;
    }
    final ({int chars, int ms})? day = week[f.dateKey];
    if (day != null) {
      week[f.dateKey] = (chars: day.chars + f.chars, ms: day.ms + f.ms);
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
    last7Days: List<ReaderBookDayStat>.unmodifiable(<ReaderBookDayStat>[
      for (final String key in weekKeys)
        (dateKey: key, chars: week[key]!.chars, ms: week[key]!.ms),
    ]),
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
    // 每块内容是一个错峰进场项：侧栏滑入的同时卡片自上而下依次浮起。
    final List<Widget> blocks = <Widget>[
      _SessionHero(session: session, onTogglePause: widget.onTogglePause),
      _PositionCard(pos: pos),
      _MetricSection(
        key: const ValueKey<String>('fushi_reader_stats_today'),
        title: t.stat_today,
        metrics: <_Metric>[
          (
            icon: Icons.schedule_outlined,
            label: t.stat_metric_time,
            value: formatStatTime(book.todayMs),
            key: 'fushi_reader_stats_today_time',
          ),
          (
            icon: Icons.notes_outlined,
            label: t.stat_metric_chars,
            value: formatGroupedInt(book.todayChars),
            key: 'fushi_reader_stats_today_chars',
          ),
          (
            icon: Icons.manage_search_outlined,
            label: t.stat_lookup,
            value: '${book.todayLookups}',
            key: 'fushi_reader_stats_today_lookups',
          ),
          (
            icon: Icons.style_outlined,
            label: t.stat_mined,
            value: '${book.todayCards}',
            key: 'fushi_reader_stats_today_cards',
          ),
        ],
      ),
      ReaderPanelCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ReaderPanelSectionLabel(
              t.reader_stats_last_7_days,
              padding: const EdgeInsets.only(bottom: 12),
            ),
            _WeekChart(days: book.last7Days),
          ],
        ),
      ),
      _MetricSection(
        key: const ValueKey<String>('fushi_reader_stats_all'),
        title: t.reader_stats_book_total,
        metrics: <_Metric>[
          (
            icon: Icons.schedule_outlined,
            label: t.stat_metric_time,
            value: formatStatTime(book.allMs),
            key: 'fushi_reader_stats_all_time',
          ),
          (
            icon: Icons.notes_outlined,
            label: t.stat_metric_chars,
            value: formatGroupedInt(book.allChars),
            key: 'fushi_reader_stats_all_chars',
          ),
        ],
      ),
      _MetricSection(
        title: t.reader_stats_time_to_finish,
        tone: ReaderPanelCardTone.tertiary,
        metrics: <_Metric>[
          (
            icon: Icons.bookmark_outline,
            label: t.reader_stats_remaining_chapter,
            value: chapterMs == null ? '—' : formatStatTime(chapterMs),
            key: 'fushi_reader_stats_finish_chapter',
          ),
          (
            icon: Icons.menu_book_outlined,
            label: t.reader_stats_remaining_book,
            value: bookMs == null ? '—' : formatStatTime(bookMs),
            key: 'fushi_reader_stats_finish_book',
          ),
        ],
      ),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: FushiPressScale(
          child: FushiTextButton.icon(
            key: const ValueKey<String>('fushi_reader_stats_full'),
            onPressed: widget.onOpenFullRecords,
            icon: const FushiIcon(Icons.chevron_right, size: 18),
            iconAlignment: IconAlignment.end,
            label: Text(t.reader_stats_full_records_open),
          ),
        ),
      ),
    ];
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
                child: FushiIconButtonControl(
                  key: const ValueKey<String>('fushi_reader_stats_close'),
                  icon: const FushiIcon(Icons.close),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: FushiEntranceScope(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < blocks.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(height: 12),
                    readerPanelStagger(i, blocks[i]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 有色卡（emphasis / tertiary）内的小标题：取卡面前景色，不用 primary（饱和
/// 色块上 primary 字对比不足）；中性卡与 Apple 走共享 [ReaderPanelSectionLabel]。
Widget _cardHeading(
  BuildContext context,
  String label,
  ReaderPanelCardTone tone, {
  EdgeInsets padding = EdgeInsets.zero,
}) {
  if (tone == ReaderPanelCardTone.neutral || isGlassDesign(context)) {
    return ReaderPanelSectionLabel(label, padding: padding);
  }
  final ThemeData theme = Theme.of(context);
  return Padding(
    padding: padding,
    child: Text(
      label,
      style: theme.textTheme.labelLarge?.copyWith(
        color: ReaderPanelCard.foregroundFor(
          context,
          tone,
        ).withValues(alpha: 0.8),
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// 本次阅读 hero：Display 级实时秒表 + 计时态 + 形状变形的暂停 / 继续键，下挂
/// 本次字数 / 字时两个大数字。
///
/// M3E 是 primaryContainer 饱和大色块（[ReaderPanelCardTone.emphasis]），Apple
/// 是分组卡 + 强调色按钮。颜色全部取当前主题，歌词模式注入的封面取色主题照样生效。
class _SessionHero extends StatelessWidget {
  const _SessionHero({required this.session, required this.onTogglePause});

  final StudySessionTotals session;
  final VoidCallback onTogglePause;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final ColorScheme cs = theme.colorScheme;
    const ReaderPanelCardTone tone = ReaderPanelCardTone.emphasis;
    final Color onSurface = ReaderPanelCard.foregroundFor(context, tone);
    final Color subtle = glass
        ? appleColorsOf(context).secondaryLabel
        : cs.onPrimaryContainer.withValues(alpha: 0.72);
    final Color dot = session.active
        ? (glass ? appleColorsOf(context).accent : cs.primary)
        : subtle;
    final Duration fade = fushiMotionDuration(context, FushiMotion.short);
    // 单位取自带数字的现有文案（17 种语言都是「$n 单位」形态），不新增 i18n key。
    final String charsUnit = t.stat_format_chars(n: '').trim();
    final String cphUnit = t.reader_stats_chars_per_hour(n: '').trim();
    return ReaderPanelCard(
      key: const ValueKey<String>('fushi_reader_stats_hero'),
      tone: tone,
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.reader_stats_session_title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: subtle,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              AnimatedContainer(
                duration: fade,
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              AnimatedSwitcher(
                duration: fade,
                child: Text(
                  session.active
                      ? t.reader_stats_clock_running
                      : t.reader_stats_clock_paused,
                  key: ValueKey<String>(
                    'fushi_reader_stats_state_${session.active}',
                  ),
                  style: theme.textTheme.labelLarge?.copyWith(color: subtle),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: ReaderStatNumber(
                    key: const ValueKey<String>('fushi_reader_stats_clock'),
                    value: formatStatClock(session.durationMs),
                    color: onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Semantics(
                identifier: 'hibiki.reader.stats.toggle_pause',
                child: _SessionPauseButton(
                  key: const ValueKey<String>('fushi_reader_stats_pause'),
                  active: session.active,
                  onPressed: onTogglePause,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 28,
            runSpacing: 12,
            children: <Widget>[
              ReaderStatNumber(
                key: const ValueKey<String>(
                  'fushi_reader_stats_session_chars',
                ),
                value: formatGroupedInt(session.chars),
                unit: charsUnit,
                color: onSurface,
                large: false,
              ),
              ReaderStatNumber(
                key: const ValueKey<String>('fushi_reader_stats_session_cph'),
                value: formatGroupedInt(
                  readingCharsPerHour(
                    chars: session.chars,
                    durationMs: session.durationMs,
                  ),
                ),
                unit: cphUnit,
                color: onSurface,
                large: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 暂停 / 继续键。M3E：primary 实色按钮，计时中为圆角方、暂停时变形为圆
/// （与有声书播放键同一套 M3E 形状变形语汇）；Apple：强调色实心圆按钮。
class _SessionPauseButton extends StatelessWidget {
  const _SessionPauseButton({
    super.key,
    required this.active,
    required this.onPressed,
  });

  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final String tooltip =
        active ? t.reader_stats_clock_pause : t.reader_stats_clock_resume;
    final IconData icon =
        active ? Icons.pause_rounded : Icons.play_arrow_rounded;
    if (isGlassDesign(context)) {
      return FushiPressScale(
        child: FushiIconButtonControl.filled(
          icon: FushiIcon(icon),
          tooltip: tooltip,
          onPressed: onPressed,
        ),
      );
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Widget glyph = AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      transitionBuilder: (Widget child, Animation<double> a) => ScaleTransition(
        scale: a,
        child: FadeTransition(opacity: a, child: child),
      ),
      child: FushiIcon(
        icon,
        key: ValueKey<IconData>(icon),
        color: cs.onPrimary,
        size: 28,
      ),
    );
    return FushiPressScale(
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          child: TweenAnimationBuilder<double>(
            // 0 = 圆角方（计时中），1 = 圆（已暂停）；回弹曲线给出 spring 感，
            // 减弱动态效果 / 墨水屏下时长归零即瞬时到位。
            tween: Tween<double>(end: active ? 0 : 1),
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.release,
            builder: (BuildContext context, double pill, Widget? child) {
              final OutlinedBorder shape = FushiMorphBorder(
                radius: 16,
                startPill: pill,
                endPill: pill,
              );
              return SizedBox.square(
                dimension: 56,
                child: DecoratedBox(
                  decoration: ShapeDecoration(color: cs.primary, shape: shape),
                  child: Material(
                    type: MaterialType.transparency,
                    shape: shape,
                    clipBehavior: Clip.antiAlias,
                    child: child,
                  ),
                ),
              );
            },
            child: InkWell(
              onTap: onPressed,
              child: Center(child: glyph),
            ),
          ),
        ),
      ),
    );
  }
}

/// 阅读位置卡：本章 / 全书两行，全书百分比用 Display 级大数字；M3E 下是
/// tertiaryContainer 色块 + 波浪进度，Apple 下分组卡 + 细线进度。
class _PositionCard extends StatelessWidget {
  const _PositionCard({required this.pos});

  final ReaderPositionSnapshot pos;

  @override
  Widget build(BuildContext context) {
    const ReaderPanelCardTone tone = ReaderPanelCardTone.tertiary;
    return ReaderPanelCard(
      tone: tone,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _cardHeading(
            context,
            t.reader_stats_position,
            tone,
            padding: const EdgeInsets.only(bottom: 12),
          ),
          _PositionRow(
            label: t.reader_stats_position_chapter,
            current: pos.chapterCurrent,
            total: pos.chapterTotal,
            keyPrefix: 'chapter',
            tone: tone,
            emphasized: false,
          ),
          const SizedBox(height: 16),
          _PositionRow(
            label: t.reader_stats_position_book,
            current: pos.bookCurrent,
            total: pos.bookTotal,
            keyPrefix: 'book',
            tone: tone,
            emphasized: true,
          ),
        ],
      ),
    );
  }
}

/// 一个指标：图标 + 读数 + 标签，[key] 挂在读数 Text 上（测试 / 探针用）。
typedef _Metric = ({IconData icon, String label, String value, String key});

/// 指标卡网格的列数（纯函数，便于测试）：宽 ≥ 520 且指标多于 2 个时 4 列，否则
/// 2 列。右侧栏（400）与窄屏底板（360~520）都是 2 列；宽底板 4 列一行排下。
int readerStatMetricColumns(double width, int count) =>
    width >= 520 && count > 2 ? 4 : 2;

/// 指标卡网格：按可用宽自适应列数（[readerStatMetricColumns]），卡片等宽、行内
/// 等高（[IntrinsicHeight]），读数长到放不下时缩字而不截断。
class _MetricSection extends StatelessWidget {
  const _MetricSection({
    super.key,
    required this.title,
    required this.metrics,
    this.tone = ReaderPanelCardTone.neutral,
  });

  final String title;
  final List<_Metric> metrics;
  final ReaderPanelCardTone tone;

  @override
  Widget build(BuildContext context) {
    const double gap = 8;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ReaderPanelSectionLabel(
          title,
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        ),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final int columns = readerStatMetricColumns(
              constraints.maxWidth,
              metrics.length,
            );
            final List<Widget> rows = <Widget>[];
            for (int start = 0; start < metrics.length; start += columns) {
              final int end = (start + columns).clamp(0, metrics.length);
              rows.add(
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int i = start; i < start + columns; i++) ...<Widget>[
                        if (i > start) const SizedBox(width: gap),
                        Expanded(
                          child: i < end
                              ? _MetricTile(metric: metrics[i], tone: tone)
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int r = 0; r < rows.length; r++) ...<Widget>[
                  if (r > 0) const SizedBox(height: gap),
                  rows[r],
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.metric, required this.tone});

  final _Metric metric;
  final ReaderPanelCardTone tone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final Color fg = ReaderPanelCard.foregroundFor(context, tone);
    final bool tinted = !glass && tone != ReaderPanelCardTone.neutral;
    final Color accent = glass
        ? appleColorsOf(context).accent
        : (tinted ? fg : theme.colorScheme.primary);
    final Color label = glass
        ? appleColorsOf(context).secondaryLabel
        : (tinted
            ? fg.withValues(alpha: 0.75)
            : theme.colorScheme.onSurfaceVariant);
    return ReaderPanelCard(
      tone: tone,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(metric.icon, size: 20, color: accent),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              metric.value,
              key: ValueKey<String>(metric.key),
              maxLines: 1,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
                height: 1.1,
                fontFeatures: const <FontFeature>[
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            metric.label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: label),
          ),
        ],
      ),
    );
  }
}

/// 近 7 天每日字数迷你柱状图：复用统计中心的 [StatBarChartPainter]（同一纵轴
/// 刻度 / 横轴标签口径）与 [StatChartEntrance]（柱高进场，减弱动态效果时直接到位）。
class _WeekChart extends StatelessWidget {
  const _WeekChart({required this.days});

  final List<ReaderBookDayStat> days;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final bool empty = days.every((ReaderBookDayStat d) => d.chars <= 0);
    if (empty) {
      return SizedBox(
        height: 48,
        child: Center(
          child: Text(
            t.stat_no_data,
            key: const ValueKey<String>('fushi_reader_stats_week_empty'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    final List<StatDayData> data = <StatDayData>[
      for (final ReaderBookDayStat d in days)
        StatDayData(dateKey: d.dateKey)
          ..chars = d.chars
          ..ms = d.ms,
    ];
    final TextStyle labelStyle = theme.textTheme.labelSmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SizedBox(
      key: const ValueKey<String>('fushi_reader_stats_week_chart'),
      height: 128,
      child: StatChartEntrance(
        replayKey: Object.hashAll(days.map((ReaderBookDayStat d) => d.chars)),
        builder: (BuildContext context, double progress) => CustomPaint(
          size: Size.infinite,
          painter: StatBarChartPainter(
            data: data,
            progress: progress,
            labelEvery: 2,
            barColor: glass
                ? appleColorsOf(context).accent
                : theme.colorScheme.primary,
            barRadius: Radius.circular(glass ? 4 : 8),
            labelColor: theme.colorScheme.onSurfaceVariant,
            labelStyle: labelStyle,
          ),
        ),
      ),
    );
  }
}

/// 阅读位置一行：`本章 / 1,842 / 4,930 字 … 37%` + 统一进度条
/// （[ReaderPanelProgress]：M3E 波浪 / Apple 细线）。[emphasized]（全书）的百分比
/// 用 Display 级大数字，本章用次一级。
class _PositionRow extends StatelessWidget {
  const _PositionRow({
    required this.label,
    required this.current,
    required this.total,
    required this.keyPrefix,
    required this.tone,
    required this.emphasized,
  });

  final String label;
  final int? current;
  final int? total;
  final String keyPrefix;
  final ReaderPanelCardTone tone;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final double? ratio = readerProgressRatio(current: current, total: total);
    final Color fg = ReaderPanelCard.foregroundFor(context, tone);
    final Color secondary = glass
        ? appleColorsOf(context).secondaryLabel
        : fg.withValues(alpha: 0.75);
    final Color? progressColor = !glass && tone == ReaderPanelCardTone.tertiary
        ? theme.colorScheme.tertiary
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    ratio == null
                        ? '—'
                        : t.reader_stats_position_progress(
                            current: formatGroupedInt(current!),
                            total: formatGroupedInt(total!),
                          ),
                    key: ValueKey<String>(
                      'fushi_reader_stats_${keyPrefix}_text',
                    ),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: secondary,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ReaderStatNumber(
              key: ValueKey<String>('fushi_reader_stats_${keyPrefix}_pct'),
              value: ratio == null ? '—' : '${(ratio * 100).round()}%',
              color: fg,
              large: emphasized,
            ),
          ],
        ),
        const SizedBox(height: 10),
        ReaderPanelProgress(
          key: ValueKey<String>('fushi_reader_stats_${keyPrefix}_bar'),
          value: ratio ?? 0,
          color: progressColor,
          semanticsLabel: label,
        ),
      ],
    );
  }
}
