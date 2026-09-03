import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 时段明细 sheet（阶段 1，统计中心大改造）：点「今日/本周/本月/全部」时段卡
/// 或热力图某日 → 底部弹出该时段内「具体看了什么、每项多久」。
///
/// 数据形状与目标口径同源：输入就是统一事实面的日行切片（[StatFact]），时段用
/// `contains(dateKey)` 谓词表达——今日/本周/本月来自 [StatWindow]，「全部」是
/// 恒真，「单日」是 `== dateKey`，五档同一条代码路径，没有特殊情况。
///
/// 组织结构（用户定案 2026-09-01）：来源分节（阅读/观看/游戏）→ 节内按所属
/// 合集分组（合集名在左作组头 + 组小计）→ 组内条目按时长倒序；无合集条目在
/// 组后平铺（有组时挂「未分组」头，无组时不加头直接列）。条目可点击跳转对应
/// 媒体（跳转前先收起 sheet）。
///
/// 合集归属与显示名因来源而异（书按 bookKey→uid 反查、游戏走 galgame 门面），
/// 由调用方注入 [StatPeriodDetailResolvers]；不注入合集解析则整节平铺。
class StatPeriodDetailResolvers {
  const StatPeriodDetailResolvers({
    required this.titleOf,
    this.collectionOf,
    this.onEntryTap,
  });

  /// 事实行 → 展示标题（**不带**合集前缀——合集名已是组头，不重复拼）。
  final String Function(StatFact fact) titleOf;

  /// 事实行 → 所属合集名；null = 未分组。
  final String? Function(StatFact fact)? collectionOf;

  /// 点条目（mediaKind + mediaKey，legacy 无身份行 mediaKey 为 ''）。sheet 已
  /// 先自行收起，回调里直接跳转即可。
  final Future<void> Function(String mediaKind, String mediaKey)? onEntryTap;
}

/// 聚合后的一条明细条目（同一媒体在时段内的合计）。
class _PeriodEntry {
  _PeriodEntry({
    required this.mediaKind,
    required this.mediaKey,
    required this.title,
    required this.collection,
  });

  final String mediaKind;
  final String mediaKey;
  final String title;
  final String? collection;
  int chars = 0;
  int ms = 0;
}

/// 弹出时段明细 sheet。[facts] 传什么域就展示什么域：域统计页传本域切片、
/// 首页/总览传完整日面（与 [studyGoalCharsForDay] 同一「域=行集」原则）。
Future<void> showStatPeriodDetailSheet(
  BuildContext context, {
  required String periodLabel,
  required bool Function(String dateKey) contains,
  required Iterable<StatFact> facts,
  required StatPeriodDetailResolvers resolvers,
}) async {
  // 按 (mediaKind, identityKey) 聚合时段内行；插入序 = 首见序，展示前再排序。
  final Map<String, _PeriodEntry> byIdentity = <String, _PeriodEntry>{};
  for (final StatFact f in facts) {
    if (!contains(f.dateKey)) continue;
    final _PeriodEntry entry = byIdentity.putIfAbsent(
      '${f.mediaKind}|${f.identityKey}',
      () => _PeriodEntry(
        mediaKind: f.mediaKind,
        mediaKey: f.mediaKey,
        title: resolvers.titleOf(f),
        collection: resolvers.collectionOf?.call(f),
      ),
    );
    entry.chars += f.chars;
    entry.ms += f.ms;
  }
  final List<_PeriodEntry> entries = byIdentity.values.toList();
  await adaptiveModalSheet<void>(
    context: context,
    builder: (BuildContext sheetContext) => _PeriodDetailSheetBody(
      periodLabel: periodLabel,
      entries: entries,
      resolvers: resolvers,
    ),
  );
}

class _PeriodDetailSheetBody extends StatelessWidget {
  const _PeriodDetailSheetBody({
    required this.periodLabel,
    required this.entries,
    required this.resolvers,
  });

  final String periodLabel;
  final List<_PeriodEntry> entries;
  final StatPeriodDetailResolvers resolvers;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    int totalChars = 0;
    int totalMs = 0;
    for (final _PeriodEntry e in entries) {
      totalChars += e.chars;
      totalMs += e.ms;
    }
    final String summary = totalMs > 0
        ? '${formatStatChars(totalChars)} · ${formatStatTime(totalMs)}'
        : formatStatChars(totalChars);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(tokens.spacing.card),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(periodLabel, style: tokens.type.sectionLabel),
            SizedBox(height: tokens.spacing.gap / 2),
            Text(summary, style: tokens.type.metadata),
            ..._section(
              context,
              tokens,
              t.home_filter_read,
              Icons.menu_book,
              kActivityMediaBook,
            ),
            ..._section(
              context,
              tokens,
              t.home_filter_watch,
              Icons.movie,
              kActivityMediaVideo,
            ),
            ..._section(
              context,
              tokens,
              t.home_filter_game,
              Icons.videogame_asset,
              kActivityMediaGame,
            ),
            if (entries.isEmpty) ...<Widget>[
              SizedBox(height: tokens.spacing.card),
              Text(t.stat_detail_empty, style: tokens.type.metadata),
            ],
          ],
        ),
      ),
    );
  }

  /// 一个来源节：节头 → 合集组（组头名在左 + 组小计在右，组间按小计时长倒序）
  /// → 组内条目按时长倒序 → 未分组条目殿后（有组时加「未分组」头）。
  List<Widget> _section(
    BuildContext context,
    FushiDesignTokens tokens,
    String label,
    IconData icon,
    String mediaKind,
  ) {
    final List<_PeriodEntry> rows =
        entries.where((_PeriodEntry e) => e.mediaKind == mediaKind).toList();
    if (rows.isEmpty) return const <Widget>[];
    final Map<String, List<_PeriodEntry>> byCollection =
        <String, List<_PeriodEntry>>{};
    final List<_PeriodEntry> ungrouped = <_PeriodEntry>[];
    for (final _PeriodEntry e in rows) {
      final String? c = e.collection;
      if (c == null || c.isEmpty) {
        ungrouped.add(e);
      } else {
        (byCollection[c] ??= <_PeriodEntry>[]).add(e);
      }
    }
    int groupMs(List<_PeriodEntry> g) =>
        g.fold(0, (int sum, _PeriodEntry e) => sum + e.ms);
    final List<MapEntry<String, List<_PeriodEntry>>> groups =
        byCollection.entries.toList()
          ..sort((a, b) => groupMs(b.value).compareTo(groupMs(a.value)));
    for (final MapEntry<String, List<_PeriodEntry>> g in groups) {
      g.value.sort((a, b) => b.ms.compareTo(a.ms));
    }
    ungrouped.sort((a, b) => b.ms.compareTo(a.ms));
    return <Widget>[
      SizedBox(height: tokens.spacing.card),
      Row(
        children: <Widget>[
          Icon(icon, size: 16, color: tokens.type.metadata.color),
          SizedBox(width: tokens.spacing.gap / 2),
          Text(label, style: tokens.type.metadata),
        ],
      ),
      SizedBox(height: tokens.spacing.gap / 2),
      for (final MapEntry<String, List<_PeriodEntry>> g in groups) ...<Widget>[
        _groupHeader(tokens, g.key, groupMs(g.value)),
        for (final _PeriodEntry e in g.value) _entryRow(context, tokens, e),
      ],
      if (ungrouped.isNotEmpty) ...<Widget>[
        if (groups.isNotEmpty)
          _groupHeader(tokens, t.stat_detail_ungrouped, groupMs(ungrouped)),
        for (final _PeriodEntry e in ungrouped) _entryRow(context, tokens, e),
      ],
    ];
  }

  Widget _groupHeader(FushiDesignTokens tokens, String name, int ms) {
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.metadata.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (ms > 0) Text(formatStatTime(ms), style: tokens.type.metadata),
        ],
      ),
    );
  }

  Widget _entryRow(
    BuildContext context,
    FushiDesignTokens tokens,
    _PeriodEntry e,
  ) {
    final bool hasCollections = e.collection != null || _sectionHasGroups(e);
    final String meta = e.ms > 0
        ? (e.chars > 0
            ? '${formatStatChars(e.chars)} · ${formatStatTime(e.ms)}'
            : formatStatTime(e.ms))
        : formatStatChars(e.chars);
    final Widget row = Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 4),
      child: Row(
        children: <Widget>[
          // 合集组内条目缩进一档，让「合集名在左」的层级读得出来。
          SizedBox(width: hasCollections ? tokens.spacing.card : 0),
          Expanded(
            child: Text(
              e.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listTitle,
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          Text(meta, style: tokens.type.metadata),
        ],
      ),
    );
    final Future<void> Function(String, String)? onTap = resolvers.onEntryTap;
    if (onTap == null) return row;
    return InkWell(
      onTap: () {
        // 先收 sheet 再跳转：sheet 是 modal route，不 pop 会盖住目标页。
        Navigator.of(context).pop();
        unawaited(onTap(e.mediaKind, e.mediaKey));
      },
      borderRadius: FushiBorderRadius.card,
      child: row,
    );
  }

  /// 该条目所在的来源节里有没有任何合集组（决定条目是否缩进对齐）。
  bool _sectionHasGroups(_PeriodEntry e) => entries.any(
        (_PeriodEntry other) =>
            other.mediaKind == e.mediaKind &&
            other.collection != null &&
            other.collection!.isNotEmpty,
      );
}
