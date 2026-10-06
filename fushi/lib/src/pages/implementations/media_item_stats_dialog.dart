/// 库页条目「查看统计」：从书 / 漫画 / 视频 / 游戏的右键或长按菜单反查这一项的
/// 学习统计（2026-09-28 用户要求）。
///
/// 只从统一事实面 [loadStatFacts] 切片（统计域 v92 读取纪律），不自己读表：
///  * 事实按 `mediaKind` + 稳定身份 `mediaKey` 归属（书 / 漫画 = bookKey，
///    有声书 / 字幕书可能记在 SRT uid 下，所以身份是**一组**；视频 = bookUid；
///    游戏 = galgames.id）。legacy 无身份行按标题回退，与 [statFactBelongsToBook]
///    同一规则；
///  * 会话走 [StatFacts.sessions]，「全部会话」复用统计页同一个
///    [showStatSessionsSheet]（可改、可删，动过就重新聚合）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';

import 'package:fushi/src/pages/implementations/stat_dashboard.dart';
import 'package:fushi/src/pages/implementations/stat_session_list.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/pages/implementations/stat_trends.dart'
    show computeCph;
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';

/// 一个库条目（或一个合集）在统计域里的身份。
class MediaItemStatsTarget {
  /// 单个条目：[mediaKind] 下的一组身份，legacy 无身份行按 [title] 回退。
  MediaItemStatsTarget({
    required String mediaKind,
    required Set<String> mediaKeys,
    required this.title,
  }) : keysByKind = <String, Set<String>>{mediaKind: mediaKeys},
       _titleFallbackKind = mediaKind;

  /// 合集：成员按各自的活动域身份归属；合集名不是任何成员的标题，所以**不做**
  /// legacy 标题回退（否则同名条目会被错吸进来）。
  MediaItemStatsTarget.collection({
    required List<MediaCollectionItemRow> members,
    required this.title,
  }) : keysByKind = _keysOfMembers(members),
       _titleFallbackKind = null;

  /// 活动域种类（`kActivityMediaBook` / `Video` / `Game`）→ 该种类下的稳定身份。
  final Map<String, Set<String>> keysByKind;

  /// 展示名。
  final String title;

  final String? _titleFallbackKind;

  static Map<String, Set<String>> _keysOfMembers(
    List<MediaCollectionItemRow> members,
  ) {
    final Map<String, Set<String>> out = <String, Set<String>>{};
    for (final MediaCollectionItemRow m in members) {
      final MediaKind? kind = MediaKind.tryParse(m.mediaType);
      if (kind == null || m.entryKey.isEmpty) continue;
      out
          .putIfAbsent(activityMediaKindOf(kind).dbValue, () => <String>{})
          .add(m.entryKey);
    }
    return out;
  }

  bool owns({
    required String mediaKind,
    required String mediaKey,
    required String title,
  }) {
    if (mediaKey.isNotEmpty) {
      return keysByKind[mediaKind]?.contains(mediaKey) ?? false;
    }
    return mediaKind == _titleFallbackKind &&
        this.title.isNotEmpty &&
        title == this.title;
  }
}

/// 一个条目的统计汇总。
class MediaItemStatsSummary {
  const MediaItemStatsSummary({
    required this.totalMs,
    required this.totalChars,
    required this.todayMs,
    required this.todayChars,
    required this.weekMs,
    required this.weekChars,
    required this.monthMs,
    required this.monthChars,
    required this.activeDays,
    required this.firstDateKey,
    required this.lastDateKey,
    required this.lookups,
    required this.cards,
    required this.sessions,
  });

  final int totalMs;
  final int totalChars;
  final int todayMs;
  final int todayChars;
  final int weekMs;
  final int weekChars;
  final int monthMs;
  final int monthChars;
  final int activeDays;
  final String? firstDateKey;
  final String? lastDateKey;
  final int lookups;
  final int cards;

  /// 属于该条目的会话，按结束时刻倒序（与 [StatFacts.sessions] 同序）。
  final List<StudySession> sessions;

  bool get isEmpty =>
      totalMs <= 0 &&
      totalChars <= 0 &&
      sessions.isEmpty &&
      lookups <= 0 &&
      cards <= 0;
}

/// 从统一事实面切出 [target] 的汇总。纯函数，窗口判据只用 [StatWindow]。
MediaItemStatsSummary summarizeMediaItemStats(
  StatFacts facts,
  MediaItemStatsTarget target, {
  required DateTime now,
}) {
  final StatWindow window = StatWindow(now);
  int totalMs = 0;
  int totalChars = 0;
  int todayMs = 0;
  int todayChars = 0;
  int weekMs = 0;
  int weekChars = 0;
  int monthMs = 0;
  int monthChars = 0;
  final Set<String> days = <String>{};
  String? first;
  String? last;
  for (final StatFact f in facts.daily) {
    if (!target.owns(
      mediaKind: f.mediaKind,
      mediaKey: f.mediaKey,
      title: f.title,
    )) {
      continue;
    }
    totalMs += f.ms;
    totalChars += f.chars;
    if (window.isToday(f.dateKey)) {
      todayMs += f.ms;
      todayChars += f.chars;
    }
    if (window.inWeek(f.dateKey)) {
      weekMs += f.ms;
      weekChars += f.chars;
    }
    if (window.inMonth(f.dateKey)) {
      monthMs += f.ms;
      monthChars += f.chars;
    }
    if (f.ms <= 0 && f.chars <= 0) continue;
    days.add(f.dateKey);
    if (first == null || f.dateKey.compareTo(first) < 0) first = f.dateKey;
    if (last == null || f.dateKey.compareTo(last) > 0) last = f.dateKey;
  }
  int lookups = 0;
  int cards = 0;
  for (final LookupMiningCounterRow c in facts.counters.lookupCounters) {
    if (!target.owns(
      mediaKind: c.sourceType,
      mediaKey: c.bookKey,
      title: c.title,
    )) {
      continue;
    }
    lookups += c.lookupCount;
    cards += c.mineCount;
  }
  final List<StudySession> sessions = <StudySession>[
    for (final StudySession s in facts.sessions)
      if (target.owns(
        mediaKind: s.mediaKind,
        mediaKey: s.mediaKey,
        title: s.title,
      ))
        s,
  ];
  return MediaItemStatsSummary(
    totalMs: totalMs,
    totalChars: totalChars,
    todayMs: todayMs,
    todayChars: todayChars,
    weekMs: weekMs,
    weekChars: weekChars,
    monthMs: monthMs,
    monthChars: monthChars,
    activeDays: days.length,
    firstDateKey: first,
    lastDateKey: last,
    lookups: lookups,
    cards: cards,
    sessions: sessions,
  );
}

/// 弹出 [target] 的统计对话框。
Future<void> showMediaItemStatsDialog(
  BuildContext context, {
  required FushiDatabase database,
  required MediaItemStatsTarget target,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext _) =>
        MediaItemStatsDialog(database: database, target: target),
  );
}

class MediaItemStatsDialog extends StatefulWidget {
  const MediaItemStatsDialog({
    super.key,
    required this.database,
    required this.target,
  });

  final FushiDatabase database;
  final MediaItemStatsTarget target;

  @override
  State<MediaItemStatsDialog> createState() => _MediaItemStatsDialogState();
}

class _MediaItemStatsDialogState extends State<MediaItemStatsDialog> {
  MediaItemStatsSummary? _summary;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final StatFacts facts = await loadStatFacts(
        widget.database,
        activityLimit: 0,
        includeCounters: true,
      );
      if (!mounted) return;
      setState(() {
        _error = null;
        _summary = summarizeMediaItemStats(
          facts,
          widget.target,
          now: DateTime.now(),
        );
      });
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MediaItemStats.load', error, stack);
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _openSessions(MediaItemStatsSummary summary) async {
    final FushiDatabase db = widget.database;
    final bool touched = await showStatSessionsSheet(
      context,
      title: widget.target.title,
      sessions: summary.sessions,
      titleOf: (StudySession s) => s.title,
      onDelete: (StudySession s) => deleteStudySession(db, s),
      onEdit: (StudySession s, StudySessionEdit edit) =>
          applyStudySessionEdit(db, s, edit),
      onClearAll: (List<StudySession> batch) => deleteStudySessions(db, batch),
    );
    if (touched && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MediaItemStatsSummary? summary = _summary;
    final Widget body;
    if (_error != null) {
      body = Text(t.media_stats_load_failed);
    } else if (summary == null) {
      body = const FushiLoadingView();
    } else if (summary.isEmpty) {
      body = FushiPlaceholderMessage(
        key: const ValueKey<String>('media-item-stats-empty'),
        icon: FushiIcons.statistics,
        message: t.media_stats_empty,
      );
    } else {
      body = _buildSummary(theme, summary);
    }
    return FushiAlertDialog(
      key: const ValueKey<String>('media-item-stats-dialog'),
      icon: const FushiIcon(FushiIcons.barChart),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(t.media_stats_title),
          if (widget.target.title.trim().isNotEmpty)
            Text(
              widget.target.title,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      content: SizedBox(width: 420, child: SingleChildScrollView(child: body)),
      actions: <Widget>[
        if (summary != null && summary.sessions.isNotEmpty)
          FushiTextButton(
            key: const ValueKey<String>('media-item-stats-sessions'),
            onPressed: () => unawaited(_openSessions(summary)),
            child: Text(t.stat_sessions_show_all),
          ),
        FushiDialogAction(
          label: MaterialLocalizations.of(context).closeButtonLabel,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  /// 2026-10 统计中心重设计：与统计页同一套指标卡（[StatHero] 2×2：累计 /
  /// 今日 / 近 7 日 / 近 30 日），其余明细是同一种卡面里的键值行，
  /// 卡与行错峰进场。
  Widget _buildSummary(ThemeData theme, MediaItemStatsSummary s) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 视频 / 游戏也可能有字数（字幕 / 文本钩子），没有就不占一格。
    final bool hasChars = s.totalChars > 0;
    final double? cph = hasChars ? computeCph(s.totalChars, s.totalMs) : null;
    String? chars(int n) => hasChars ? formatStatChars(n) : null;
    final List<Widget> tiles = <Widget>[
      StatKpiTile(
        icon: Icons.functions,
        label: t.media_stats_total,
        value: formatStatTime(s.totalMs),
        caption: chars(s.totalChars),
      ),
      StatKpiTile(
        icon: FushiIcons.calendar,
        label: t.stat_today,
        value: formatStatTime(s.todayMs),
        caption: chars(s.todayChars),
      ),
      StatKpiTile(
        icon: FushiIcons.calendar,
        label: t.media_stats_last_7_days,
        value: formatStatTime(s.weekMs),
        caption: chars(s.weekChars),
      ),
      StatKpiTile(
        icon: FushiIcons.calendar,
        label: t.stat_last_30_days,
        value: formatStatTime(s.monthMs),
        caption: chars(s.monthChars),
      ),
    ];
    final List<(String, String)> rows = <(String, String)>[
      if (cph != null) (t.stat_metric_speed, formatStatCph(cph)),
      (t.media_stats_active_days, t.stat_format_days(n: '${s.activeDays}')),
      (
        t.media_stats_sessions,
        t.stat_sessions_count(n: '${s.sessions.length}'),
      ),
      if (s.firstDateKey != null) (t.media_stats_first_date, s.firstDateKey!),
      if (s.lastDateKey != null) (t.media_stats_last_date, s.lastDateKey!),
      if (s.lookups > 0) (t.stat_lookup, '${s.lookups}'),
      if (s.cards > 0) (t.stat_mined, '${s.cards}'),
    ];
    return FushiEntranceScope(
      child: Column(
        key: const ValueKey<String>('media-item-stats-summary'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiStaggeredEntrance(
            index: 0,
            child: StatHero(tiles: tiles, padding: EdgeInsets.zero),
          ),
          FushiStaggeredEntrance(
            index: 1,
            child: Padding(
              padding: EdgeInsets.only(top: tokens.spacing.card),
              child: FushiCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final (String label, String value) in rows)
                      Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: tokens.spacing.gap / 2,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                label,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            SizedBox(width: tokens.spacing.gap),
                            Flexible(
                              flex: 2,
                              child: Text(
                                value,
                                textAlign: TextAlign.end,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
