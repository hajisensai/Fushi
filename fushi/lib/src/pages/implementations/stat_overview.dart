import 'package:flutter/material.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';

/// 统计中心总览（2026-10 重设计）独有的展示件：媒体类型筛选。版式件（页面
/// 骨架、指标区、目标面板、空数据态）与三个域页共用，见 `stat_dashboard.dart`。
/// 数据层一行不碰——这里只按筛选切页面经 `loadStatFacts` 取回的日面 / 会话。

/// 总览的媒体类型筛选（全部 / 阅读 / 观看 / 游戏）。
///
/// 「全部」= 跨域（与三个域 tab 之和恒等，见 `StatCounterFacts`）；其余三档
/// 与对应域 tab 是同一份切片判据：日面 / 会话按 `mediaKind`，计数面按
/// [StatSourceKind]（[source]）。
enum StatMediaFilter { all, book, video, game }

extension StatMediaFilterX on StatMediaFilter {
  /// 计数面（查词 / 制卡 / 收藏）的来源；null = 跨域。
  StatSourceKind? get source => switch (this) {
    StatMediaFilter.all => null,
    StatMediaFilter.book => StatSourceKind.book,
    StatMediaFilter.video => StatSourceKind.video,
    StatMediaFilter.game => StatSourceKind.game,
  };

  /// 某个媒体种类（`kActivityMedia*`）是否落在本档里。
  bool includesKind(String mediaKind) => switch (this) {
    StatMediaFilter.all => true,
    StatMediaFilter.book => mediaKind == kActivityMediaBook,
    StatMediaFilter.video => mediaKind == kActivityMediaVideo,
    StatMediaFilter.game => mediaKind == kActivityMediaGame,
  };

  String get label => switch (this) {
    StatMediaFilter.all => t.home_filter_all,
    StatMediaFilter.book => t.home_filter_read,
    StatMediaFilter.video => t.home_filter_watch,
    StatMediaFilter.game => t.home_filter_game,
  };

  IconData get icon => switch (this) {
    StatMediaFilter.all => Icons.apps_rounded,
    StatMediaFilter.book => Icons.menu_book_outlined,
    StatMediaFilter.video => Icons.movie_outlined,
    StatMediaFilter.game => Icons.sports_esports_outlined,
  };
}

/// 纯函数：按筛选切日面行。
List<StatFact> filterStatFacts(
  Iterable<StatFact> daily,
  StatMediaFilter filter,
) => <StatFact>[
  for (final StatFact f in daily)
    if (filter.includesKind(f.mediaKind)) f,
];

/// 纯函数：按筛选切会话流（保持原有的倒序）。
List<StudySession> filterStudySessions(
  Iterable<StudySession> sessions,
  StatMediaFilter filter,
) => <StudySession>[
  for (final StudySession s in sessions)
    if (filter.includesKind(s.mediaKind)) s,
];

/// 媒体类型筛选条：一行可聚焦的 chip（键盘 / 手柄方向键遍历、Enter 选中）。
class StatMediaFilterBar extends StatelessWidget {
  const StatMediaFilterBar({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final StatMediaFilter selected;
  final ValueChanged<StatMediaFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Semantics(
      container: true,
      label: t.stat_center_media_filter,
      child: Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          for (final StatMediaFilter f in StatMediaFilter.values)
            FushiSelectableChip(
              key: ValueKey<String>('stat-media-filter-${f.name}'),
              label: f.label,
              leadingIcon: f.icon,
              selected: f == selected,
              onSelected: (_) => onChanged(f),
            ),
        ],
      ),
    );
  }
}
