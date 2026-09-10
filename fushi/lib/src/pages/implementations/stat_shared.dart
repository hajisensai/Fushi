import 'package:flutter/material.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_hourly_breakdown.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';

/// 三个域统计页「按媒体」列表共用的一行（用户 2026-09-08「统计全改成游戏那种」：
/// 原游戏页 `_buildGameRow` 的形态提成共享件）：左域图标 · 标题（+ 合集标签）·
/// 一到两行 meta · 右侧主值（时长）· 有 [onTap] 时带 chevron。
/// [onDelete] 挂在移动端长按 + 桌面端右键（经 [ContextMenuTrigger] 走绑定表，BUG-2111）。
Widget buildStatMediaRow(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String meta,
  required String trailing,
  String? collectionName,
  String? meta2,
  VoidCallback? onTap,
  VoidCallback? onDelete,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final ColorScheme colors = Theme.of(context).colorScheme;
  final TextStyle metaStyle = tokens.type.metadata.copyWith(
    color: colors.onSurfaceVariant,
  );
  final Widget card = FushiCard(
    onTap: onTap,
    onLongPress: onDelete,
    child: Row(
      children: <Widget>[
        Icon(icon, color: colors.primary),
        SizedBox(width: tokens.spacing.gap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              if (collectionName != null) ...<Widget>[
                SizedBox(height: tokens.spacing.gap / 4),
                buildStatCollectionLabel(context, collectionName),
              ],
              SizedBox(height: tokens.spacing.gap / 2),
              Text(
                meta,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: metaStyle,
              ),
              if (meta2 != null) ...<Widget>[
                SizedBox(height: tokens.spacing.gap / 4),
                Text(
                  meta2,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: metaStyle,
                ),
              ],
            ],
          ),
        ),
        SizedBox(width: tokens.spacing.gap),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(
            trailing,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (onTap != null) ...<Widget>[
          SizedBox(width: tokens.spacing.gap / 2),
          Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
        ],
      ],
    ),
  );
  return Padding(
    padding: EdgeInsets.symmetric(
      horizontal: tokens.spacing.card,
      vertical: tokens.spacing.gap / 2,
    ),
    child: onDelete == null
        ? card
        : ContextMenuTrigger(
            onInvoke: contextMenuInvoker(onDelete),
            child: card,
          ),
  );
}

/// 统计页「分析」折叠区：三个域 tab 收敛到「时段卡 → 每日图 → 最近会话 → 按媒体」
/// 的游戏页骨架后，阅读页的 KPI 条 / 趋势 / 今日环 / 速度摘要 / 来源分布 / 小时×格式
/// 与视频页的小时分布都下沉到这里，默认收起。纯 UI 状态，不持久化。
class StatAnalysisFold extends StatefulWidget {
  const StatAnalysisFold({required this.children, super.key});

  /// 展开后按序堆叠的区块（各区块自带横向留白）。
  final List<Widget> children;

  @override
  State<StatAnalysisFold> createState() => _StatAnalysisFoldState();
}

class _StatAnalysisFoldState extends State<StatAnalysisFold> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.card,
            tokens.spacing.card + tokens.spacing.gap,
            tokens.spacing.card,
            0,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: FushiBorderRadius.card,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        t.stat_analysis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_expanded) ...widget.children,
      ],
    );
  }
}

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
      child: FushiPlaceholderMessage(
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
    this.onTap,
  });

  final String label;
  final String primaryValue;
  final List<StatSummaryLine> lines;

  /// 点卡片 → 时段明细 sheet（阶段 1，统计中心大改造）。null = 纯展示卡。
  final VoidCallback? onTap;
}

/// 统计中心 tab 嵌入态外壳（阶段 2）：右对齐动作行 + 内容。三域统计页在
/// TabBarView 里不再套各自的 FushiPageScaffold——那会叠出双 Scaffold / 双顶栏，
/// 且每个 scaffold 都往 PageScrollRegistry 注册滚动控制器互踩手柄翻页目标。
Widget buildEmbeddedStatTab(
  BuildContext context,
  List<Widget> actions,
  Widget body,
) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  return Column(
    children: <Widget>[
      Padding(
        padding: EdgeInsets.only(right: tokens.spacing.card),
        child: Align(
          alignment: Alignment.centerRight,
          child: Row(mainAxisSize: MainAxisSize.min, children: actions),
        ),
      ),
      Expanded(child: body),
    ],
  );
}

/// 汇总卡两列布局的最小列宽（dp）。低于此宽度时「1234 小时 56 分钟」这类长主值
/// 会被 [FittedBox] 压到读不出来，不如退回单列。
const double kStatPeriodSummaryMinColumnWidth = 144;

/// 列宽低于此值时卡片切紧凑内边距。手机两列每列只有 ~155dp，[FushiCard] 默认的
/// 20dp 四边内边距会吃掉四成可用宽度，主值被压得比单列还小。
const double kStatPeriodSummaryCompactColumnWidth = 200;

/// 统计页滚动内容的收尾留白：原有的两倍卡片间距 + 底部安全区（BUG-2440）。
///
/// [FushiPageScaffold] 的 SafeArea 已改成 `bottom: false`（内容画得到屏幕最底，
/// 不再留一条谁也用不了的底色空白），代价是 body 自己要把 inset 补进滚动内容，
/// 否则静止时最后一行被 home indicator / 手势条压住。三域统计页的独立页路径与
/// 统计中心 tab 路径（[buildEmbeddedStatTab]）的滚动视图都直抵屏幕底部，补偿相同，
/// 所以补在这一层而不是各自的 scaffold 分支里。
Widget buildStatTailSliver(BuildContext context) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  return SliverPadding(
    padding: EdgeInsets.only(
      bottom: tokens.spacing.card * 2 + bottomSafeInsetOf(context),
    ),
  );
}

/// 统计页共用的四周期汇总卡网格：能放下两列就 2×2，放不下才单列。
///
/// BUG：旧实现按「可用宽度 ≥ 380」判两列。这层外面还有 [FushiSpacingTokens.card]
/// （20dp）的左右内边距，360dp 宽的手机到这里只剩 320dp，连 412dp 的大屏手机也只
/// 有 372dp——阈值结构上高于任何手机，所以手机端永远单列。改成按**实际算出的列宽**
/// 判：列宽够放一张卡就两列，跟屏幕宽度阈值脱钩。
Widget buildStatPeriodSummaryGrid(
  BuildContext context,
  List<StatPeriodSummary> summaries,
) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final double wideGap = tokens.spacing.gap + tokens.spacing.gap / 2;
  final double compactGap = tokens.spacing.gap;

  return Padding(
    padding: EdgeInsets.all(tokens.spacing.card),
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final StatPeriodSummaryLayout layout = resolveStatPeriodSummaryLayout(
          maxWidth: constraints.maxWidth,
          wideGap: wideGap,
          compactGap: compactGap,
        );
        final List<Widget> panels = summaries
            .map((StatPeriodSummary summary) => _StatPeriodSummaryCard(
                  summary: summary,
                  compact: layout.compact,
                ))
            .toList();
        if (layout.columnWidth == null) {
          return Column(
            children: <Widget>[
              for (int i = 0; i < panels.length; i++) ...<Widget>[
                if (i > 0) SizedBox(height: layout.gap),
                panels[i],
              ],
            ],
          );
        }
        return Wrap(
          spacing: layout.gap,
          runSpacing: layout.gap,
          children: <Widget>[
            for (final Widget panel in panels)
              SizedBox(width: layout.columnWidth, child: panel),
          ],
        );
      },
    ),
  );
}

/// [buildStatPeriodSummaryGrid] 解出的布局：列宽为 null 表示单列。
class StatPeriodSummaryLayout {
  const StatPeriodSummaryLayout({
    required this.columnWidth,
    required this.gap,
    required this.compact,
  });

  /// 两列时每列的宽度；null = 放不下两列，走单列。
  final double? columnWidth;

  /// 卡片之间的间距（两列时同时用于横纵）。
  final double gap;

  /// 列窄到需要卡片用紧凑内边距。
  final bool compact;
}

/// 纯函数：按可用宽度解出汇总卡网格布局，方便直接测宽度→列数的判据。
///
/// 先按 [wideGap] 试两列；差一点点放不下时改用 [compactGap] 再试一次（挤出的
/// 几 dp 常常正好够 360dp 手机排下两列），仍不够才退单列。单列时间距一律用
/// [wideGap]，纵向不缺空间。
StatPeriodSummaryLayout resolveStatPeriodSummaryLayout({
  required double maxWidth,
  required double wideGap,
  required double compactGap,
}) {
  // 无界宽度（横向滚动容器里）算不出列宽，只能单列。
  if (!maxWidth.isFinite) {
    return StatPeriodSummaryLayout(
      columnWidth: null,
      gap: wideGap,
      compact: false,
    );
  }
  for (final double gap in <double>[wideGap, compactGap]) {
    final double columnWidth = (maxWidth - gap) / 2;
    if (columnWidth >= kStatPeriodSummaryMinColumnWidth) {
      return StatPeriodSummaryLayout(
        columnWidth: columnWidth,
        gap: gap,
        compact: columnWidth < kStatPeriodSummaryCompactColumnWidth,
      );
    }
  }
  return StatPeriodSummaryLayout(
    columnWidth: null,
    gap: wideGap,
    compact: false,
  );
}

class _StatPeriodSummaryCard extends StatelessWidget {
  const _StatPeriodSummaryCard({
    required this.summary,
    this.compact = false,
  });

  final StatPeriodSummary summary;

  /// 手机两列下每列只有 ~155dp，卡片默认 20dp 内边距会把主值挤到读不出来；
  /// 紧凑态改用 [FushiSpacingTokens.rowHorizontal]（16dp），多让出 8dp 正文宽。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle? subStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        );
    final Widget card = FushiCard(
      padding: compact
          ? EdgeInsets.all(tokens.spacing.rowHorizontal)
          : EdgeInsets.all(tokens.spacing.card),
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
    if (summary.onTap == null) return card;
    return InkWell(
      onTap: summary.onTap,
      borderRadius: FushiBorderRadius.card,
      child: card,
    );
  }
}

/// 最近 30 天时长柱状图（视频 / 游戏统计共用）。
Widget buildStatDailyDurationChartSection(
  BuildContext context,
  List<StatDayData> daily,
) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
              axisScaleOf: statDurationAxisScale,
            ),
          ),
        ),
      ],
    ),
  );
}

/// v76 读取端身份分组（v39「读取端按 title 回退」的成文契约）：把带可空身份的
/// 统计行按「身份优先、unique-title 归并」分组。
///
///  - [identityOf] 非空的行按身份分组（同名不同视频各自一组，根治展示层互串）；
///  - 身份为空的行（v76 前遗留 / sync 降级权威行）：其 title 恰好只被一个身份组
///    占用 → 归并进该组（主流场景「一个视频跨新旧数据」仍是单 tile，与 v39 迁移
///    「按 title 唯一匹配回填」同判据）；否则独立成无身份组（[identity] = null，
///    歧义遗留如实分开展示）。
///
/// 组顺序：先身份组（按行序首见），后无身份组。吸收过无身份行的组置
/// [absorbedUnattributed]，删除路径据此决定是否连带删该 title 的无身份行。
class StatIdentityGroup<T> {
  StatIdentityGroup({required this.identity, required this.title});

  /// 身份键（视频=bookUid，计数行=bookKey）；null = 无身份遗留组。
  final String? identity;

  /// 展示标题（组内首见行的 title 快照）。
  final String title;

  /// 是否吸收了同 title 的无身份行（删除时连带的判据）。
  bool absorbedUnattributed = false;

  final List<T> rows = <T>[];
}

List<StatIdentityGroup<T>> groupStatRowsByIdentity<T>(
  List<T> rows, {
  required String Function(T) identityOf,
  required String Function(T) titleOf,
  Set<String> ambiguousTitles = const <String>{},
}) {
  final Map<String, StatIdentityGroup<T>> byIdentity =
      <String, StatIdentityGroup<T>>{};
  final List<T> unattributed = <T>[];
  for (final T row in rows) {
    final String identity = identityOf(row);
    if (identity.isEmpty) {
      unattributed.add(row);
      continue;
    }
    byIdentity
        .putIfAbsent(identity,
            () => StatIdentityGroup<T>(identity: identity, title: titleOf(row)))
        .rows
        .add(row);
  }
  // title → 拥有它的身份组（unique-title 归并判据）。按组内**全部** title 快照
  // 注册（review-9：改名视频一个 uid 组横跨多个 title，只登记首见 title 会让新
  // title 的无身份行错落成孤儿组）。
  final Map<String, List<StatIdentityGroup<T>>> ownersByTitle =
      <String, List<StatIdentityGroup<T>>>{};
  for (final StatIdentityGroup<T> g in byIdentity.values) {
    final Set<String> groupTitles = <String>{
      for (final T row in g.rows) titleOf(row),
    };
    for (final String title in groupTitles) {
      ownersByTitle.putIfAbsent(title, () => <StatIdentityGroup<T>>[]).add(g);
    }
  }
  final Map<String, StatIdentityGroup<T>> orphanGroups =
      <String, StatIdentityGroup<T>>{};
  for (final T row in unattributed) {
    final String title = titleOf(row);
    final List<StatIdentityGroup<T>>? owners = ownersByTitle[title];
    // 吸收需同时过两道判据（review-2）：行宇宙里恰好一个身份组占用该 title，
    // **且**调用方的权威面（如 video_books 库表）没有把该 title 判为多身份
    // （[ambiguousTitles]）。行宇宙判据单独用会误吸：同名双视频都只有无身份
    // 遗留行时，任何一方偶然产生的第一条带身份行会把混合遗留整体吸走并随它
    // 被删——这正是本套分组要消灭的连坐。
    if (owners != null &&
        owners.length == 1 &&
        !ambiguousTitles.contains(title)) {
      owners.single
        ..absorbedUnattributed = true
        ..rows.add(row);
    } else {
      orphanGroups
          .putIfAbsent(
              title, () => StatIdentityGroup<T>(identity: null, title: title))
          .rows
          .add(row);
    }
  }
  return <StatIdentityGroup<T>>[
    ...byIdentity.values,
    ...orphanGroups.values,
  ];
}

/// 统一事实面行的按身份分组（BUG-2216）：阅读统计页「按书」与时段明细 sheet 都走
/// 这一个入口，与视频域 `computeVideoStats` 同一套 [groupStatRowsByIdentity] 契约——
/// 有 mediaKey 按身份分组；legacy 无身份行（书已删 / 库表同名歧义）在行宇宙里恰好
/// 一个身份组占用该 title 且不在 [ambiguousTitles] 时并入，否则独立成无身份组。
/// 此前阅读域裸按 `identityKey` 分组：删书后 legacy 行与段各成一组、同名两条。
List<StatIdentityGroup<StatFact>> groupStatFactsByIdentity(
  Iterable<StatFact> facts, {
  Set<String> ambiguousTitles = const <String>{},
}) => groupStatRowsByIdentity<StatFact>(
  facts.toList(growable: false),
  identityOf: (StatFact f) => f.mediaKey,
  titleOf: (StatFact f) => f.title,
  ambiguousTitles: ambiguousTitles,
);

/// TODO-1204：把查词/制卡计数行按 [LookupMiningCounterRow.title] 聚合成
/// (查词数, 制卡数)，供 per-book tile 展示。无书查词（title 空）不入
/// tile，只进汇总面板。聚合键与字数/时长 tile 的 title 一致。
///
/// **book 域专用**：书标题导入期强制去重、与 bookKey 双射，按 title 聚合即按身份
/// 聚合。视频域标题可重复，必须走 [groupStatRowsByIdentity]，且观看/计数/收藏三个
/// 行宇宙必须**同一次**分组（见 video_stat_aggregates 的 computeVideoStats）。
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
/// 的名字；任一步缺失返回 null。锁死统计页 'epub|<uid>' / 'video|<bookUid>' 键契约
/// （v83 成员表 entryKey：epub=`epub_books.uid`（调用方持 bookKey 时先换算）、
/// video=bookUid）。
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
/// （与 [statCollectionName] 同契约：epub=uid（v83）/ srt=srtUid / video=bookUid）；
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

/// 一次会话的时间范围文案：`2026-07-24 21:03 → 22:41`（游戏详情页会话列表与统计页
/// 会话流同一口径）。委托 [FushiTimeFormat]（起点 = dateHourMinute，终点 = hourMinute）。
String formatStatSessionRange(int startMs, int endMs) {
  final DateTime start = DateTime.fromMillisecondsSinceEpoch(startMs);
  final DateTime end = DateTime.fromMillisecondsSinceEpoch(endMs);
  return '${FushiTimeFormat.dateHourMinute(start)} → '
      '${FushiTimeFormat.hourMinute(end)}';
}

/// 统计页时长外显：不足 1 小时套 i18n 分钟文案，否则套 i18n 时+分文案。
String formatStatTime(int ms) {
  final int totalMin = ms ~/ 60000;
  if (totalMin < 60) return t.stat_format_minutes(n: totalMin);
  final int h = totalMin ~/ 60;
  final int m = totalMin % 60;
  return t.stat_format_hours_minutes(h: h, m: m);
}

/// 每日 / 每周字数目标编辑对话框。写 0 = 清除（隐藏）该目标。返回 true 表示用户
/// 点了保存并已写穿偏好，调用方据此重建。
///
/// 阅读统计 tab 与统计中心总览 tab 编辑的是**同一个**持久化目标
/// （`readingGoal*Chars`），所以只有一份表单；两处各写一份的话，单位、清零语义和
/// 校验规则一改就只改到一处。
Future<bool> showStatGoalEditDialog(
  BuildContext context,
  AppModel appModel,
) async {
  final TextEditingController dailyController = TextEditingController(
    text: appModel.readingGoalDailyChars == 0
        ? ''
        : appModel.readingGoalDailyChars.toString(),
  );
  final TextEditingController weeklyController = TextEditingController(
    text: appModel.readingGoalWeeklyChars == 0
        ? ''
        : appModel.readingGoalWeeklyChars.toString(),
  );

  final bool? saved = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final FushiDesignTokens tokens = FushiDesignTokens.of(dialogContext);
      return AlertDialog(
        title: Text(t.stat_goal_set),
        // helperText 让内容变高：横屏/小窗下用滚动兜底，不再顶到溢出。
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // BUG-1075：单位（与首页仪表盘目标对话框同一批 i18n key，两处编辑的是
              // 同一个持久化目标）。口径说明行已按用户要求删除——统计口径由实际计入的
              // 来源（阅读/漫画/视频字幕/游戏文本）自解释，不再在文案里逐项列举。
              TextField(
                controller: dailyController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t.stat_goal_daily,
                  suffixText: t.stat_goal_unit_chars,
                ),
              ),
              SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
              TextField(
                controller: weeklyController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t.stat_goal_weekly,
                  suffixText: t.stat_goal_unit_chars,
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t.dialog_save),
          ),
        ],
      );
    },
  );

  final String dailyText = dailyController.text.trim();
  final String weeklyText = weeklyController.text.trim();
  dailyController.dispose();
  weeklyController.dispose();

  if (saved != true) return false;

  final int daily = int.tryParse(dailyText) ?? 0;
  final int weekly = int.tryParse(weeklyText) ?? 0;
  await appModel.setReadingGoalDailyChars(daily < 0 ? 0 : daily);
  await appModel.setReadingGoalWeeklyChars(weekly < 0 ? 0 : weekly);
  return true;
}

/// 统计页字数外显：数字部分走当前语言的紧凑写法（[formatCompactCount]：CJK
/// `6.8万`、其余语言 `68K`），再套上 i18n 的「N characters」文案。
///
/// 倍率单位不再进 i18n 词条——它是语言属性而非可翻译文案，旧的
/// `stat_format_chars_wan` 键把中文万进制硬贴给了 13 种非 CJK 语言（BUG-935）。
/// 全统计页只此一份实现（阅读页原私有 `_formatChars` 已并入）。
String formatStatChars(int chars) =>
    t.stat_format_chars(n: formatStatCharsAxis(chars));

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

/// 「今日按小时」单色柱状图区块（视频统计用：观看时长没有阅读面之分，只有一带）。
/// [hourlyMs] 为 0-23 每小时的毫秒值。
Widget buildStatHourlyChartSection(BuildContext context, List<int> hourlyMs) {
  final colorScheme = Theme.of(context).colorScheme;
  return _buildStatHourlyChartSection(
    context,
    bands: <StatHourlyBand>[
      StatHourlyBand(values: hourlyMs, color: colorScheme.tertiary),
    ],
    legendBands: const <StatHourlyFormatBand>[],
    showUnattributedNote: false,
  );
}

/// 「今日按小时」按阅读面（format）分色堆叠的柱状图区块（阅读统计用）。
///
/// [breakdown] 里的 [StatHourlyFormatBand.unattributed] 是 v67 之前写入时就没存
/// 身份的历史合计，它单独成一带、用中性色、并在图例下附一句说明——**不归入任何一个
/// 阅读面**。
Widget buildStatHourlyFormatChartSection(
  BuildContext context,
  StatHourlyBreakdown breakdown,
) {
  final colorScheme = Theme.of(context).colorScheme;
  final List<StatHourlyFormatBand> active = breakdown.activeBands;
  return _buildStatHourlyChartSection(
    context,
    bands: <StatHourlyBand>[
      for (final StatHourlyFormatBand band in active)
        StatHourlyBand(
          values: breakdown.valuesOf(band),
          color: statHourlyBandColor(band, colorScheme),
        ),
    ],
    legendBands: statHourlyLegendBands(active),
    showUnattributedNote: active.contains(StatHourlyFormatBand.unattributed),
  );
}

/// 分带填充色。
///
/// 未区分历史刻意用中性的 [ColorScheme.outlineVariant]，而不是第四个品类色：它不是
/// 一种书，配一个和 EPUB / PDF / 漫画平级的彩色只会让人以为它也是某一类。
Color statHourlyBandColor(StatHourlyFormatBand band, ColorScheme scheme) =>
    switch (band) {
      StatHourlyFormatBand.epub => scheme.tertiary,
      StatHourlyFormatBand.pdf => scheme.primary,
      StatHourlyFormatBand.manga => scheme.secondary,
      StatHourlyFormatBand.unattributed => scheme.outlineVariant,
    };

/// 分带图例文案。
String statHourlyBandLabel(StatHourlyFormatBand band) => switch (band) {
      StatHourlyFormatBand.epub => t.stat_hourly_band_epub,
      StatHourlyFormatBand.pdf => t.stat_hourly_band_pdf,
      StatHourlyFormatBand.manga => t.stat_hourly_band_manga,
      StatHourlyFormatBand.unattributed => t.stat_hourly_band_unattributed,
    };

/// 该画哪些图例项。
///
/// 只有一带、且那一带是真实阅读面时不画图例——「一个条目的图例」不提供任何信息，
/// 只是噪音。但只要含未区分历史就必须画，哪怕它是唯一一带：没有图例的中性柱子会被
/// 当成某一类的读书时长，那正是这次要消除的误读。
List<StatHourlyFormatBand> statHourlyLegendBands(
    List<StatHourlyFormatBand> activeBands) {
  if (activeBands.length <= 1 &&
      !activeBands.contains(StatHourlyFormatBand.unattributed)) {
    return const <StatHourlyFormatBand>[];
  }
  return activeBands;
}

Widget _buildStatHourlyChartSection(
  BuildContext context, {
  required List<StatHourlyBand> bands,
  required List<StatHourlyFormatBand> legendBands,
  required bool showUnattributedNote,
}) {
  final tokens = FushiDesignTokens.of(context);
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
              bands: bands,
              barRadius: tokens.radii.chipCorner,
              labelColor: colorScheme.onSurfaceVariant,
              labelStyle: tokens.type.metadata.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (legendBands.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap / 2,
            children: <Widget>[
              for (final StatHourlyFormatBand band in legendBands)
                _StatHourlyLegendChip(band: band),
            ],
          ),
        ],
        if (showUnattributedNote) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          Text(
            t.stat_hourly_unattributed_note,
            style: tokens.type.metadata.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        SizedBox(height: tokens.spacing.card + tokens.spacing.gap),
      ],
    ),
  );
}

/// 图例一项：与柱子同色的小色块 + 文案。
class _StatHourlyLegendChip extends StatelessWidget {
  const _StatHourlyLegendChip({required this.band});

  final StatHourlyFormatBand band;

  @override
  Widget build(BuildContext context) {
    final tokens = FushiDesignTokens.of(context);
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: tokens.spacing.gap,
          height: tokens.spacing.gap,
          decoration: BoxDecoration(
            color: statHourlyBandColor(band, colorScheme),
            borderRadius: BorderRadius.all(tokens.radii.chipCorner),
          ),
        ),
        SizedBox(width: tokens.spacing.gap / 2),
        Text(
          statHourlyBandLabel(band),
          style: tokens.type.metadata.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
