import 'package:flutter/material.dart';
import 'package:hibiki/src/pages/implementations/activity_feed.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 阅读、视频与游戏统计页共用的聚合 / 格式化 / 页面状态 / 卡片与图表辅助。

/// 统一统计页的加载、错误、空态分派。
///
/// 三个页面只提供自己的数据判据和内容；状态优先级与空态视觉不再各复制一份三元表达式。
Widget buildStatPageBody({
  required bool loading,
  required String? error,
  required bool isEmpty,
  required Widget Function() loadingBuilder,
  required Widget Function(String error) errorBuilder,
  required String emptyMessage,
  required Widget Function() contentBuilder,
}) {
  if (loading) return loadingBuilder();
  if (error != null) return errorBuilder(error);
  if (isEmpty) {
    return Center(
      child: HibikiPlaceholderMessage(
        icon: Icons.bar_chart_outlined,
        message: emptyMessage,
      ),
    );
  }
  return contentBuilder();
}

/// 汇总周期卡的一条次级指标。[label] 为空时只显示值（如阅读卡主字数下的时长）。
class StatSummaryLine {
  const StatSummaryLine({this.label, required this.value});

  final String? label;
  final String value;
}

/// 今天 / 本周 / 本月 / 全部中的一个汇总卡数据。
class StatPeriodSummary {
  const StatPeriodSummary({
    required this.label,
    required this.primaryValue,
    this.lines = const <StatSummaryLine>[],
  });

  final String label;
  final String primaryValue;
  final List<StatSummaryLine> lines;
}

/// 统计页共用的四周期汇总卡网格：宽屏 2×2，窄屏单列。
Widget buildStatPeriodSummaryGrid(
  BuildContext context,
  List<StatPeriodSummary> summaries,
) {
  final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
  final double gap = tokens.spacing.gap + tokens.spacing.gap / 2;
  final List<Widget> panels = summaries
      .map((StatPeriodSummary summary) =>
          _StatPeriodSummaryCard(summary: summary))
      .toList();

  return Padding(
    padding: EdgeInsets.all(tokens.spacing.card),
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool twoColumns =
            constraints.maxWidth.isFinite && constraints.maxWidth >= 380;
        if (!twoColumns) {
          return Column(
            children: <Widget>[
              for (int i = 0; i < panels.length; i++) ...<Widget>[
                if (i > 0) SizedBox(height: gap),
                panels[i],
              ],
            ],
          );
        }
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final Widget panel in panels)
              SizedBox(
                width: (constraints.maxWidth - gap) / 2,
                child: panel,
              ),
          ],
        );
      },
    ),
  );
}

class _StatPeriodSummaryCard extends StatelessWidget {
  const _StatPeriodSummaryCard({required this.summary});

  final StatPeriodSummary summary;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final TextStyle? subStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        );
    return HibikiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            summary.label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          SizedBox(height: tokens.spacing.gap),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              summary.primaryValue,
              maxLines: 1,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          for (final StatSummaryLine line in summary.lines) ...<Widget>[
            SizedBox(height: tokens.spacing.gap / 2),
            Text(
              line.label == null ? line.value : '${line.label}: ${line.value}',
              style: subStyle,
            ),
          ],
        ],
      ),
    );
  }
}

/// 最近 30 天时长柱状图（视频 / 游戏统计共用）。
Widget buildStatDailyDurationChartSection(
  BuildContext context,
  List<StatDayData> daily,
) {
  final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
  final ColorScheme colorScheme = Theme.of(context).colorScheme;
  return Padding(
    padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t.stat_last_30_days,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
        SizedBox(
          height: 160,
          child: CustomPaint(
            size: Size.infinite,
            painter: StatBarChartPainter(
              data: daily,
              barColor: colorScheme.primary,
              barRadius: tokens.radii.chipCorner,
              labelColor: colorScheme.onSurfaceVariant,
              labelStyle: tokens.type.metadata.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              valueOf: statMsValue,
              labelFormatter: formatStatDurationAxis,
            ),
          ),
        ),
      ],
    ),
  );
}

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

/// 纯函数：把 '<mediaType>|<entryKey>' 归属键解析成合集名。[key] 命中折叠归属的主
/// collectionId（[primaryByEntry]，即 getPrimaryCollectionIdByEntry），再取 [namesById]
/// 的名字；任一步缺失返回 null。锁死统计页 'epub|<bookKey>' / 'video|<bookUid>' 键契约
/// （书架成员表 entryKey：epub=bookKey、video=bookUid）。
String? statCollectionName(
  String key,
  Map<String, int> primaryByEntry,
  Map<int, String> namesById,
) {
  final int? cid = primaryByEntry[key];
  if (cid == null) return null;
  return namesById[cid];
}

/// 纯函数：非合集上下文的「合集名 + 条目名」显示名解析（显示名只在渲染层拼，DB
/// 落库保持原名——BUG-1018 惯例）。[entryKey] 是 '<mediaType>|<entryKey>' 归属键
/// （与 [statCollectionName] 同契约：epub=bookKey / srt=srtUid / video=bookUid）；
/// 命中合集返回 (合集名, 原名)，未命中 (null, 原名)——调用方据此决定
/// 「标题=合集名、副标题=条目名」还是「标题=条目名」。
({String? collectionName, String title}) resolveEntryDisplayTitle({
  required String entryKey,
  required String rawTitle,
  required Map<String, int> primaryByEntry,
  required Map<int, String> collectionNamesById,
}) {
  return (
    collectionName:
        statCollectionName(entryKey, primaryByEntry, collectionNamesById),
    title: rawTitle,
  );
}

/// [resolveEntryDisplayTitle] 的单行拼接便捷函数：命中合集返回「合集名 - 条目名」
/// （分隔符 ' - ' 与制卡 documentTitle 口径一致，见 composeVideoMiningDocumentTitle；
/// 同样不做合集名==条目名去重），未命中原样返回条目名。活动时间轴等单行场景用。
String collectionQualifiedTitle({
  required String entryKey,
  required String rawTitle,
  required Map<String, int> primaryByEntry,
  required Map<int, String> collectionNamesById,
}) {
  final String? name =
      statCollectionName(entryKey, primaryByEntry, collectionNamesById);
  if (name == null || name.isEmpty) return rawTitle;
  return '$name - $rawTitle';
}

/// 统计页 per-book / per-video tile 的「所属合集」小标签（文件夹图标 + 合集名），
/// 阅读统计与视频统计共用（同一视觉）。合集名为 null 时调用方不渲染本 widget。
Widget buildStatCollectionLabel(
  BuildContext context,
  String collectionName,
) {
  final ColorScheme colorScheme = Theme.of(context).colorScheme;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Icon(
        Icons.folder_outlined,
        size: 13,
        color: colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          collectionName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    ],
  );
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

/// 统计页字数外显：≥1 万套「万」文案（保留 1 位小数），否则整数字文案。
/// 与阅读统计页原私有 `_formatChars` 同口径，供热力图气泡等复用（机械去重）。
String formatStatChars(int chars) {
  if (chars >= 10000) {
    return t.stat_format_chars_wan(n: (chars / 10000).toStringAsFixed(1));
  }
  return t.stat_format_chars(n: chars);
}

/// 相对时间外显：把 [activityRelativeTime] 的结构化结果套上 i18n 文案
/// （刚刚 / N 分钟前 / N 小时前 / N 天前）。
///
/// [activityRelativeTime] 刻意留在纯数据层不碰 i18n，这里是它唯一的 widget 层
/// 映射：首页活动时间轴与 Bangumi 同步卡的「上次同步」共用同一口径，不各写一份
/// switch（否则单位阈值一改就只改到一处）。
String formatActivityRelativeTime(int timestampMs, DateTime now) {
  final ActivityRelativeTime rel = activityRelativeTime(timestampMs, now);
  switch (rel.unit) {
    case ActivityRelativeUnit.justNow:
      return t.activity_just_now;
    case ActivityRelativeUnit.minutesAgo:
      return t.activity_minutes_ago(n: rel.value);
    case ActivityRelativeUnit.hoursAgo:
      return t.activity_hours_ago(n: rel.value);
    case ActivityRelativeUnit.daysAgo:
      return t.activity_days_ago(n: rel.value);
  }
}

/// 热力图气泡日期标签：`M-dd`；跨年补年份成 `Y-M-dd`。[dateKey] 形如 `2026-07-18`
/// （[statDateKey] 格式）；无法解析时原样返回。
String formatStatHeatmapDay(String dateKey) {
  final DateTime? d = DateTime.tryParse(dateKey);
  if (d == null) return dateKey;
  final DateTime now = DateTime.now();
  final String dd = d.day.toString().padLeft(2, '0');
  if (d.year == now.year) return '${d.month}-$dd';
  return '${d.year}-${d.month}-$dd';
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
