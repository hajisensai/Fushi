/// 阅读器内「阅读统计」浮层（ッツ / Hoshi Reader Statistics 形态）。
///
/// 四块：本次会话（实时秒表）/ 今日 / 累计（后两块按**本书**身份从统一事实面
/// `loadStatFacts` 切片，统计域 v92 纪律：展示只从 `StatFacts` 派生）/ 预计读完
/// （本章 / 全书剩余字数 ÷ 速度）。账本只在 `StudyClock` 一本，本层不持有任何会话
/// 累计副本——会话读数是每秒采样的函数（同底部状态行）。
///
/// 排版是**纯文字行**：一块一列，每行左标签、右数值（[_StatRows]）。此前是等宽三
/// 格 + 竖分隔线的横排卡片，格宽 = 卡宽 / 3 与文字长度无关——手机窄屏上「速度」
/// 那格的 `12345 / h`、时长那格的 `1:23:45` 稳定被省略成「…」，统计浮层最该看的
/// 数字反而看不全。纵向排一行给数值整条行宽，任何语言的标签和任何位数的数值都不
/// 再互相挤。
///
/// 手动计时开关是浮层底部的整宽按钮（[_TrackingToggleButton]），与底栏按钮同级
/// （高度走 `density.controlHeight`）：它此前是「本次会话」小标题旁 18px 的紧凑
/// IconButton，触摸目标远小于 48dp 的可点击下限，手机上难点中。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudySessionTotals;

import 'package:fushi/src/pages/implementations/stat_trends.dart'
    show computeCph, kMinCphSampleMs;
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show ReaderSideSheetSectionLabel;
import 'package:fushi/src/reader/reader_status_footer.dart'
    show readingCharsPerHour;
import 'package:fushi/src/stats/stat_facts.dart'
    show StatFact, statFactBelongsToBook;
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/utils.dart';

/// 本书的今日 / 累计阅读量（字数 + 毫秒）。
typedef ReaderBookStatTotals = ({
  int todayChars,
  int todayMs,
  int allChars,
  int allMs,
});

const ReaderBookStatTotals kEmptyReaderBookStatTotals = (
  todayChars: 0,
  todayMs: 0,
  allChars: 0,
  allMs: 0,
);

/// 从阅读域日面事实里切出**本书**的今日 / 累计。身份优先 `mediaKey == bookKey`；
/// legacy 无身份行按 title 回退（与阅读统计页的按书分组同一规则）。
ReaderBookStatTotals summarizeReaderBookStats(
  Iterable<StatFact> dailyBooks, {
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
  return (
    todayChars: todayChars,
    todayMs: todayMs,
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
  final double? sessionCph = session.chars > 0
      ? computeCph(session.chars, session.durationMs)
      : null;
  if (sessionCph != null && sessionCph > 0) return sessionCph;
  final double? allCph = computeCph(book.allChars, book.allMs);
  return (allCph != null && allCph > 0) ? allCph : null;
}

/// 今日 / 累计卡的速度文案（BUG-2218）：与统计页同一口径 [computeCph]（最小样本
/// [kMinCphSampleMs]），样本不足显示与统计页一致的 `—`，不再把几十秒的脏样本外推成
/// 爆表数字。会话卡是实时秒表，仍走 [readingCharsPerHour] 开局即显 `0 / h`。
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

class ReaderStatisticsDialog extends StatefulWidget {
  const ReaderStatisticsDialog({
    super.key,
    required this.sessionTotals,
    required this.loadBookTotals,
    required this.remainingChapterChars,
    required this.remainingBookChars,
    required this.trackingPaused,
    required this.onToggleTracking,
    this.tick = const Duration(seconds: 1),
  });

  /// 会话累计读口（每 [tick] 采样一次，账本在 StudyClock）。
  final StudySessionTotals Function() sessionTotals;

  /// 本书今日 / 累计（从统一事实面加载，进浮层时读一次）。
  final Future<ReaderBookStatTotals> Function() loadBookTotals;

  final int? remainingChapterChars;
  final int? remainingBookChars;
  final Duration tick;

  /// 会话计时是否被用户手动暂停（读口，每 tick 采样）。
  final bool Function() trackingPaused;

  /// 「本次会话」旁的 ▶/⏸：手动暂停 / 继续计时（切屏自动暂停之外的手动开关）。
  final VoidCallback onToggleTracking;

  @override
  State<ReaderStatisticsDialog> createState() => _ReaderStatisticsDialogState();
}

class _ReaderStatisticsDialogState extends State<ReaderStatisticsDialog> {
  Timer? _ticker;
  ReaderBookStatTotals? _book;
  ({int seconds, int chars, bool active, bool paused})? _lastSnapshot;

  @override
  void initState() {
    super.initState();
    // 会话读数按秒采样，但只在秒 / 字数 / 计时态变了才重建（暂停时零重建）。
    _ticker = Timer.periodic(widget.tick, (_) {
      if (!mounted) return;
      final StudySessionTotals s = widget.sessionTotals();
      final ({int seconds, int chars, bool active, bool paused}) snap = (
        seconds: s.durationMs ~/ 1000,
        chars: s.chars,
        active: s.active,
        paused: widget.trackingPaused(),
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
    final bool paused = widget.trackingPaused();
    final ReaderBookStatTotals book = _book ?? kEmptyReaderBookStatTotals;
    final double? finishCph = readerFinishCph(session: session, book: book);
    final int? chapterMs = estimateFinishMs(
      remainingChars: widget.remainingChapterChars,
      cph: finishCph,
    );
    final int? bookMs = estimateFinishMs(
      remainingChars: widget.remainingBookChars,
      cph: finishCph,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.gap,
        tokens.spacing.page,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.reading_statistics,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                key: const ValueKey<String>('fushi_reader_stats_close'),
                icon: const Icon(Icons.close),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          Padding(
            // 标题行的关闭键贴着 gap 的右边距，正文行不跟着贴——补到与左边一样的
            // page，纯文字行的右侧数值才与左侧标签对称。
            padding: EdgeInsets.only(
              right: tokens.spacing.page - tokens.spacing.gap,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ReaderSideSheetSectionLabel(t.reader_stats_session),
                _StatRows(
                  cells: _metricCells(
                    session.chars,
                    session.durationMs,
                    live: true,
                  ),
                ),
                ReaderSideSheetSectionLabel(
                  '${t.stat_today} · ${t.reader_stats_this_book}',
                ),
                _StatRows(
                  cells: _metricCells(
                    book.todayChars,
                    book.todayMs,
                    live: false,
                  ),
                ),
                ReaderSideSheetSectionLabel(
                  '${t.stat_all_time} · ${t.reader_stats_this_book}',
                ),
                _StatRows(
                  cells: _metricCells(book.allChars, book.allMs, live: false),
                ),
                ReaderSideSheetSectionLabel(t.reader_stats_time_to_finish),
                _StatRows(
                  cells: <_StatCell>[
                    _StatCell(
                      label: t.reader_stats_finish_chapter,
                      value: chapterMs == null
                          ? '—'
                          : formatStatClock(chapterMs),
                    ),
                    _StatCell(
                      label: t.reader_stats_finish_book,
                      value: bookMs == null ? '—' : formatStatClock(bookMs),
                    ),
                  ],
                ),
                SizedBox(height: tokens.spacing.page),
                _TrackingToggleButton(
                  paused: paused,
                  onPressed: () {
                    widget.onToggleTracking();
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// [live] = 本次会话秒表（开局即显 0，不套样本门槛）；今日 / 累计走统计口径
  /// [readerBookSpeedLabel]（BUG-2218）。
  List<_StatCell> _metricCells(int chars, int ms, {required bool live}) {
    final String speed = live
        ? '${readingCharsPerHour(chars: chars, durationMs: ms)}'
        : readerBookSpeedLabel(chars, ms);
    return <_StatCell>[
      _StatCell(label: t.stat_metric_chars, value: '$chars'),
      _StatCell(label: t.stat_metric_speed, value: speed, unit: '/ h'),
      _StatCell(label: t.stat_metric_time, value: formatStatClock(ms)),
    ];
  }
}

class _StatCell {
  const _StatCell({required this.label, required this.value, this.unit});

  final String label;
  final String value;
  final String? unit;
}

/// 一块统计：每行左标签、右数值（等宽数字），行间横分隔线。
///
/// 纵向排而不是横排等宽格子——横排时格宽恒为卡宽 / 3，与文字实际长度无关，窄屏
/// 上数值只能省略成「…」；纵排把整条行宽让给数值，标签按剩余宽度收缩，数值永不
/// 被截断（[Text] 不加 `overflow`，宽度由它自己的内在尺寸决定）。
class _StatRows extends StatelessWidget {
  const _StatRows({required this.cells});

  final List<_StatCell> cells;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle labelStyle = theme.textTheme.bodyMedium!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final TextStyle valueStyle = theme.textTheme.titleMedium!.copyWith(
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      color: theme.colorScheme.onSurface,
    );
    final TextStyle unitStyle = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: tokens.radii.cardRadius,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < cells.length; i++) ...<Widget>[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                color: theme.colorScheme.outlineVariant,
              ),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.gap * 1.5,
                vertical: tokens.spacing.gap,
              ),
              child: Row(
                children: <Widget>[
                  // 标签是唯一可收缩的一侧：长标签折行 / 收窄，数值照常整数显示。
                  Expanded(child: Text(cells[i].label, style: labelStyle)),
                  SizedBox(width: tokens.spacing.gap * 1.5),
                  Text.rich(
                    TextSpan(
                      text: cells[i].value,
                      style: valueStyle,
                      children: <InlineSpan>[
                        if (cells[i].unit != null)
                          TextSpan(text: ' ${cells[i].unit}', style: unitStyle),
                      ],
                    ),
                    textAlign: TextAlign.end,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 浮层底部的手动计时开关：整宽、底栏级高度（`density.controlHeight`）的按钮。
///
/// 暂停中用实心 [FilledButton]（计时停着是需要用户注意的非常态），计时中用
/// tonal 变体。文案沿用旧 tooltip 的 `t.play` / `t.pause`——这两个 key 在 17 种
/// 语言都有真翻译，新造一对「暂停计时 / 继续计时」只会在 15 种语言上回落成英文。
/// key 沿用旧的紧凑 IconButton 那一个，桌面端快捷键集成测试按它断言浮层里有计时
/// 开关。
class _TrackingToggleButton extends StatelessWidget {
  const _TrackingToggleButton({required this.paused, required this.onPressed});

  final bool paused;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget icon = Icon(
      paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
    );
    final Widget label = Text(paused ? t.play : t.pause);
    const ValueKey<String> key = ValueKey<String>(
      'fushi_reader_stats_tracking_toggle',
    );
    return SizedBox(
      width: double.infinity,
      height: tokens.density.controlHeight,
      child: paused
          ? FilledButton.icon(
              key: key,
              onPressed: onPressed,
              icon: icon,
              label: label,
            )
          : FilledButton.tonalIcon(
              key: key,
              onPressed: onPressed,
              icon: icon,
              label: label,
            ),
    );
  }
}
