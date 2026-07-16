import 'package:flutter/material.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 阅读统计页与视频统计页**字节级相同**的聚合 / 格式化 / 图表辅助（机械去重抽出，
/// 原先两页各持一份）。页面特有的加载与布局逻辑仍留在各自页面。

/// TODO-1204：把查词/制卡计数行按 [LookupMiningCounterRow.title] 聚合成
/// (查词数, 制卡数)，供 per-book / per-video tile 展示。无书查词（title 空）不入
/// tile，只进汇总面板。聚合键与字数/时长 tile 的 title 一致。
Map<String, ({int lookups, int mines})> aggregateStatCountersByTitle(
    List<LookupMiningCounterRow> rows) {
  final Map<String, ({int lookups, int mines})> out =
      <String, ({int lookups, int mines})>{};
  for (final LookupMiningCounterRow r in rows) {
    if (r.title.isEmpty) continue;
    final ({int lookups, int mines}) prev =
        out[r.title] ?? (lookups: 0, mines: 0);
    out[r.title] = (
      lookups: prev.lookups + r.lookupCount,
      mines: prev.mines + r.mineCount,
    );
  }
  return out;
}

/// TODO-1252：把收藏活行按 [FavoriteWordRow.title] 聚合成每本书/每个视频的收藏数，
/// 供 per-book / per-video tile 展示。无书收藏（title 空）不入 tile，只进汇总面板。
/// 聚合键与查词/制卡 tile 的 title 一致。收藏取消即删行 → 聚合活行天然回落。
Map<String, int> aggregateStatFavoritesByTitle(List<FavoriteWordRow> rows) {
  final Map<String, int> out = <String, int>{};
  for (final FavoriteWordRow r in rows) {
    if (r.title.isEmpty) continue;
    out[r.title] = (out[r.title] ?? 0) + 1;
  }
  return out;
}

/// 统计页时长外显：不足 1 小时套 i18n 分钟文案，否则套 i18n 时+分文案。
String formatStatTime(int ms) {
  final int totalMin = ms ~/ 60000;
  if (totalMin < 60) return t.stat_format_minutes(n: totalMin);
  final int h = totalMin ~/ 60;
  final int m = totalMin % 60;
  return t.stat_format_hours_minutes(h: h, m: m);
}

/// 「今日按小时」柱状图区块（标题 + [StatHourlyChartPainter] 画布）。
/// [hourlyMs] 为 0-23 每小时的毫秒值。
Widget buildStatHourlyChartSection(BuildContext context, List<int> hourlyMs) {
  final tokens = HibikiDesignTokens.of(context);
  final colorScheme = Theme.of(context).colorScheme;
  return Padding(
    padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.stat_today_hourly,
            style: Theme.of(context).textTheme.titleMedium),
        SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
        SizedBox(
          height: 140,
          child: CustomPaint(
            size: Size.infinite,
            painter: StatHourlyChartPainter(
              hourlyMs: hourlyMs,
              barColor: colorScheme.tertiary,
              barRadius: tokens.radii.chipCorner,
              labelColor: colorScheme.onSurfaceVariant,
              labelStyle: tokens.type.metadata.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        SizedBox(height: tokens.spacing.card + tokens.spacing.gap),
      ],
    ),
  );
}
