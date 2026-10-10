import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_day_reset_hour_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_hourly_breakdown.dart';
import 'package:fushi/src/pages/implementations/stat_trends.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';

/// 三个域统计页「按媒体」列表共用的一行（用户 2026-09-08「统计全改成游戏那种」：
/// 原游戏页 `_buildGameRow` 的形态提成共享件）：左域图标 · 标题（+ 合集标签）·
/// 一到两行 meta · 右侧主值（时长）· 有 [onTap] 时带 chevron。
/// [onDelete] 挂在移动端长按 + 桌面端右键（经 [ContextMenuTrigger] 走绑定表，BUG-2111）。
///
/// [cover]：媒体封面（书架 / 视频库 / 游戏库同一条封面解析链
/// `resolveMediaCoverImage`）。三个域的「按媒体」列表都给每行一个固定 2:3
/// 封面槽（Niratan「Book Ranking」同款）：有封面画封面，没有 / 加载失败画
/// [icon] 占位，整列左缘对齐。
Widget buildStatMediaRow(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String meta,
  required String trailing,
  String? collectionName,
  String? meta2,
  ImageProvider? cover,
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
        buildStatCoverSlot(context, icon: icon, cover: cover),
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
        // 2026-10 体验优化：删除入口统一为可见按钮（与会话列表一致），长按 /
        // 右键仍保留作快捷方式。
        if (onDelete != null)
          FushiIconButtonControl(
            tooltip: t.stat_delete_title,
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        if (onTap != null) ...<Widget>[
          SizedBox(width: tokens.spacing.gap / 2),
          FushiIcon(Icons.chevron_right, color: colors.onSurfaceVariant),
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

/// 统计列表可点行的最小高度（2026-10 体验优化：触控目标 ≥ 48）。
const double kStatRowMinHeight = 48;

/// 「按媒体」行封面槽宽（逻辑像素，高 = 宽 × 1.4，接近 2:3 海报 / 书封）。
const double kStatMediaCoverWidth = 40;

/// 会话行封面槽宽（会话行是 compact 列表项，槽比「按媒体」行窄一号）。
const double kStatSessionCoverWidth = 32;

/// 统计行的定宽 2:3 封面槽：有封面画封面，没有 / 加载失败画 [icon] 占位，
/// 所以同一列里有封面、没封面的行左缘对齐。「按媒体」行与会话行共用这一个，
/// 别在两处各搭一遍（占位 / 失败回退 / 圆角三处口径要一致）。
Widget buildStatCoverSlot(
  BuildContext context, {
  required IconData icon,
  ImageProvider? cover,
  double width = kStatMediaCoverWidth,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  // 无封面占位：中性填充 + 次级前景色的单色图标（与排行榜封面占位同口径），
  // 不用主色图标——一列里一半行亮着强调色会抢掉右侧主值的视线。
  final Widget placeholder = Center(
    child: FushiIcon(
      icon,
      size: width * 0.6,
      color: fushiNeutralSecondaryForeground(context),
    ),
  );
  return ClipRRect(
    borderRadius: tokens.radii.chipRadius,
    child: Container(
      width: width,
      height: width * 1.4,
      color: fushiNeutralBlockColor(context),
      child: cover == null
          ? placeholder
          : Image(
              image: cover,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => placeholder,
            ),
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
          // 2026-10 统计中心重设计：折叠头是一张可聚焦的卡（键盘 / 手柄 Enter
          // 展开），chevron 随展开转半圈、内容按 FushiMotion 时长展开——减弱
          // 动态效果时两者瞬间到位。
          child: FushiCard(
            onTap: () => setState(() => _expanded = !_expanded),
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.card,
              vertical: tokens.spacing.gap,
            ),
            child: Semantics(
              expanded: _expanded,
              child: Row(
                children: <Widget>[
                  FushiIcon(Icons.insights_outlined, color: colors.primary),
                  SizedBox(width: tokens.spacing.gap),
                  Expanded(
                    child: Text(
                      t.stat_analysis,
                      style: statSectionTitleStyle(context),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: fushiMotionDuration(context, FushiMotion.medium),
                    curve: FushiMotion.standard,
                    child: FushiIcon(
                      Icons.expand_more,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.enter,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.children,
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// 阅读、视频与游戏统计页共用的聚合 / 格式化 / 页面状态 / 卡片与图表辅助。

/// 统一统计页的加载、错误分派。
///
/// 空数据不在这里分派（2026-10 统计中心重设计）：各页在内容里画
/// `StatDashboardEmpty`——指标区照常显示，版式与有数据时一致，而不是整页换成
/// 一行居中的占位文案。
Widget buildStatPageBody({
  required bool loading,
  required String? error,
  required Widget Function() loadingBuilder,
  required Widget Function(String error) errorBuilder,
  required Widget Function() contentBuilder,
}) {
  // 不滚动的加载 / 错误态让开叠放在上面的浮动页头（正文铺到页头底下时顶部
  // 让位在 MediaQuery padding 里）；滚动内容自己消费（[StatDashboardBody]）。
  if (loading) return SafeArea(bottom: false, child: loadingBuilder());
  if (error != null) {
    return SafeArea(bottom: false, child: errorBuilder(error));
  }
  return contentBuilder();
}

/// 汇总卡上「无数据」的统一占位（2026-10 体验优化：速度等可能算不出的行不再
/// 时有时无，统一渲染并显示该占位，四张卡行数一致）。
const String kStatEmptyValue = '—';

/// 统计页区块卡内标题的统一字重（2026-10 统计中心重设计）：MD3 = titleMedium
/// w600 onSurface；Apple = 同字号 label 色。卡外的大区块标题走 [FushiSectionTitle]。
TextStyle statSectionTitleStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  final TextStyle base = theme.textTheme.titleMedium ?? const TextStyle();
  return base.copyWith(
    fontWeight: FontWeight.w600,
    color: isGlassDesign(context)
        ? appleColorsOf(context).label
        : theme.colorScheme.onSurface,
  );
}

/// 统计中心的区块卡（2026-10 重设计）：一张 [FushiCard]，卡头 = 可选图标 +
/// 标题 + 可选副标题 / 尾部控件，卡身 = [child]。图表、日历、范围汇总共用这
/// 一种外框，两套设计系统的卡面、圆角、内边距由 [FushiCard] 一处决定。
class StatSectionCard extends StatelessWidget {
  const StatSectionCard({
    required this.title,
    required this.child,
    super.key,
    this.icon,
    this.subtitle,
    this.trailing,
    this.margin,
  });

  final String title;
  final Widget child;
  final IconData? icon;

  /// 标题下的一行说明（如所选区间、区间总时长）。
  final String? subtitle;

  /// 卡头行尾控件。
  final Widget? trailing;

  /// 卡外边距；null = 左右上 [FushiSpacingTokens.card]、下 0（区块纵向堆叠时
  /// 两卡之间的间距由下一张卡的上边距提供）。
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String? sub = subtitle;
    return Padding(
      padding: margin ??
          EdgeInsets.fromLTRB(
            tokens.spacing.card,
            tokens.spacing.card,
            tokens.spacing.card,
            0,
          ),
      child: FushiCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(
              header: true,
              child: Row(
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    FushiIcon(icon, size: 20, color: colors.primary),
                    SizedBox(width: tokens.spacing.gap),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: statSectionTitleStyle(context),
                        ),
                        if (sub != null && sub.isNotEmpty)
                          Text(
                            sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.type.metadata.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // 行尾控件按自然宽贴右（2026-10-09：此前 Flexible 与标题 Expanded
                  // 平分整行，单颗图标被推到卡片中间，PDF 图 3「按钮乱了」）。
                  if (trailing != null) trailing!,
                ],
              ),
            ),
            SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
            child,
          ],
        ),
      ),
    );
  }
}

/// 「所选范围」卡的一条额外指标（[label] + [value]）。
class StatSummaryLine {
  const StatSummaryLine({this.label, required this.value});

  final String? label;
  final String value;
}

/// 一个统计 tab 交给「统计设置」的东西（2026-10-09 统计中心精简）：页头不再有
/// 目标 / 刷新 / 清空 / 重置时刻四颗按钮，后两项收进统计设置弹窗（目标改由首页
/// 每日目标卡进入、刷新砍掉——切 tab / 回到页面本来就会重聚合）。
@immutable
class StatTabSettings {
  const StatTabSettings({required this.onClearAll, this.enabled = true});

  /// 「清空统计」：清本 tab 那一域（总览 = 三域一起）。确认弹窗由回调自己弹。
  final VoidCallback onClearAll;

  /// 加载 / 清空进行中为 false：设置里的清空项随之禁用，防连点。
  final bool enabled;
}

/// 标记：这个统计 tab 嵌在统计中心的 TabBarView 里（统计中心的页头已让出顶部
/// padding，tab 不必再套 SafeArea）。
class StatCenterTabScope extends InheritedWidget {
  const StatCenterTabScope({required super.child, super.key});

  static bool isIn(BuildContext context) =>
      context.getInheritedWidgetOfExactType<StatCenterTabScope>() != null;

  @override
  bool updateShouldNotify(StatCenterTabScope oldWidget) => false;
}

/// 统计中心 tab 嵌入态外壳（阶段 2）。三域统计页在 TabBarView 里不再套各自的
/// FushiPageScaffold——那会叠出双 Scaffold / 双顶栏，且每个 scaffold 都往
/// PageScrollRegistry 注册滚动控制器互踩手柄翻页目标。
///
/// 2026-10-09 起页头不再有任何动作按钮：统计设置（[StatSettingsButton]）挂在各页
/// 范围条行尾（`StatRangeBar.trailing`）与空数据态顶部，独立页与统计中心 tab
/// 同一位置，所以这里只剩「不在统计中心时让开顶部 padding」。
Widget buildEmbeddedStatTab(BuildContext context, Widget body) {
  if (StatCenterTabScope.isIn(context)) return body;
  return SafeArea(bottom: false, child: body);
}

/// 统计设置入口：点开 [showStatSettingsDialog]（「今日」重置时刻 + 清空 [settings]
/// 那一域的统计）。2026-10-09 统计中心精简：页头原来的目标 / 刷新 / 清空 / 重置
/// 时刻四颗按钮收成这一颗，挂在范围条行尾——页头第一行只留返回键与页签，手机宽
/// 下「总览 / 阅读 / 观看 / 游戏」才摆得下。弹窗副标题写当前 Profile（v105 统计按
/// Profile 隔离）。
class StatSettingsButton extends ConsumerWidget {
  const StatSettingsButton({required this.settings, super.key});

  final StatTabSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FushiIconButton(
      key: const ValueKey<String>('stat-settings-button'),
      icon: FushiIcons.settings,
      tooltip: t.stat_center_settings,
      onTap: () => unawaited(
        showStatSettingsDialog(
          context,
          ref.read(appProvider),
          settings: settings,
          profileName: ref.read(profileViewModelProvider).activeProfile?.name,
        ),
      ),
    );
  }
}

/// 范围条行尾的两颗按钮：「明细」+ 统计设置（[StatSettingsButton]）。
///
/// 「明细」打开时段明细 sheet（`showStatPeriodDetailSheet`：来源分节 → 合集分组
/// → 按作品时长倒序），时段 = 范围条当前所选区间（日 / 自然周 / 月 / 年 / 全部 /
/// 自定义，与总览同一个 [StatRange]），事实行 = 本 tab 那一域。2026-10-09 删掉
/// 「时段明细」卡片后统计中心里没有别处能看按作品的明细（首页热力图点日仍有），
/// 入口挂在范围条上而不是再加一张卡：明细本来就是「所选范围」的下钻。
class StatRangeActions extends StatelessWidget {
  const StatRangeActions({
    required this.settings,
    required this.onOpenDetail,
    super.key,
  });

  final StatTabSettings settings;

  /// 打开所选范围的时段明细 sheet。
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('stat-range-detail-button'),
          icon: FushiIcons.toc,
          tooltip: t.stat_range_detail_open,
          onTap: onOpenDetail,
        ),
        StatSettingsButton(settings: settings),
      ],
    );
  }
}

/// 空数据态顶部的统计设置行（范围条不出现时，重置时刻 / 清空仍要够得着）。
Widget buildStatSettingsHeader(StatTabSettings settings) => Align(
  alignment: AlignmentDirectional.centerEnd,
  child: StatSettingsButton(settings: settings),
);

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

/// 时长柱状图（四个统计 tab 共用）。[title] 缺省为「近 30 天」；范围图表经
/// `buildStatRangeChartSection` 传区间标题与按柱数稀疏的 [labelEvery]。
///
/// 2026-10 统计中心重设计：整块是一张 [StatSectionCard]（标题 + 区间 / 合计副标题），
/// 柱子经 [StatChartEntrance] 从 0 长到满高；换范围 / 换筛选（数据签名变了）时重播。
Widget buildStatDailyDurationChartSection(
  BuildContext context,
  List<StatDayData> daily, {
  String? title,
  String? subtitle,
  int labelEvery = 5,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final ColorScheme colorScheme = Theme.of(context).colorScheme;
  final StatChartColors chartColors = statChartColorsOf(context);
  return StatSectionCard(
    title: title ?? t.stat_last_30_days,
    subtitle: subtitle,
    icon: Icons.bar_chart_rounded,
    child: SizedBox(
      height: 168,
      child: StatChartEntrance(
        replayKey: statDayDataSignature(daily),
        builder: (BuildContext context, double progress) => CustomPaint(
          size: Size.infinite,
          painter: StatBarChartPainter(
            data: daily,
            barColor: chartColors.series,
            barRadius: tokens.radii.chipCorner,
            labelColor: colorScheme.onSurfaceVariant,
            labelStyle: tokens.type.metadata.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            valueOf: statMsValue,
            axisScaleOf: statDurationAxisScale,
            labelEvery: labelEvery,
            progress: progress,
          ),
        ),
      ),
    ),
  );
}

/// 纯函数：一组柱数据的签名（柱数 + 首尾键 + 时长 / 字数合计）。[StatChartEntrance]
/// 拿它当重播键：同一份数据重建（父级 setState）不重播，换了范围 / 筛选才重播。
Object statDayDataSignature(List<StatDayData> data) {
  int ms = 0;
  int chars = 0;
  for (final StatDayData d in data) {
    ms += d.ms;
    chars += d.chars;
  }
  return Object.hash(
    data.length,
    data.isEmpty ? '' : data.first.dateKey,
    data.isEmpty ? '' : data.last.dateKey,
    ms,
    chars,
  );
}

/// 图表进场动画（2026-10 统计中心重设计）：把 0→1 的进度喂给 [builder]，柱高 /
/// 环弧随之长满。时长取 [FushiMotion.long]、曲线 [FushiMotion.enter]——两套设计
/// 系统共用；墨水屏 / 系统「减弱动态效果」下 [fushiMotionDuration] 归零，图表
/// 直接画满。[replayKey] 变化时重播一次。
class StatChartEntrance extends StatelessWidget {
  const StatChartEntrance({
    required this.replayKey,
    required this.builder,
    super.key,
  });

  final Object replayKey;
  final Widget Function(BuildContext context, double progress) builder;

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.long);
    return TweenAnimationBuilder<double>(
      key: ValueKey<Object>(replayKey),
      tween: Tween<double>(begin: duration == Duration.zero ? 1 : 0, end: 1),
      duration: duration,
      curve: FushiMotion.enter,
      builder: (BuildContext context, double value, Widget? _) =>
          builder(context, value),
    );
  }
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
      FushiIcon(
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
/// 阅读统计 tab、统计中心总览 tab 与首页仪表盘编辑的是**同一个**持久化目标
/// （`readingGoal*Chars`），所以只有一份表单；多处各写一份的话，单位、清零语义和
/// 校验规则一改就只改到一处。
///
/// 2026-10 体验优化：首页原有一套只编每日目标的 `_DailyGoalDialog`（带预设 chip
/// 与近 7 日参考），统计页这套只有两个裸输入框——两套对话框合并为本函数 +
/// [StatGoalEditDialog]：每日目标 + 预设 + 近 7 日参考，多处入口共用（每周目标
/// 2026-10-10 用户拍板删除：统计中心目标卡删掉后它只能设、不显示进度）。
/// [recentDailyAverage] 为近 7 日日均字数（与目标同口径，见
/// [statRecentDailyAverageChars]）；<=0 不显示参考行。
Future<bool> showStatGoalEditDialog(
  BuildContext context,
  AppModel appModel, {
  int recentDailyAverage = 0,
}) async {
  final StatGoalEditResult? result = await showAppDialog<StatGoalEditResult>(
    context: context,
    builder: (BuildContext _) => StatGoalEditDialog(
      initialDailyChars: appModel.readingGoalDailyChars,
      recentDailyAverage: recentDailyAverage,
    ),
  );
  if (result == null) return false;
  await appModel.setReadingGoalDailyChars(result.daily);
  return true;
}

/// [dayKeys]（调用方从自己的统计窗口取，如 `w.lastDayKeys(7)`）的日均字数，
/// **与目标同口径**（学习域 [studyGoalCharsForDay]）：给「我该填多少」一个
/// 真实参考值（BUG-1075）。无数据日按 0 计入分母（真实反映日均，不是活跃日均）。
int statRecentDailyAverageChars(
  Iterable<StatFact> daily,
  List<String> dayKeys,
) {
  if (dayKeys.isEmpty) return 0;
  int total = 0;
  for (final String key in dayKeys) {
    total += studyGoalCharsForDay(daily, key);
  }
  return total ~/ dayKeys.length;
}

/// [StatGoalEditDialog] 保存时的结果（已规整为 >= 0；0 = 关闭该目标）。
typedef StatGoalEditResult = ({int daily});

/// 目标编辑表单。独立 StatefulWidget **自持** controller 生命周期：dispose 跟随
/// 路由销毁（弹出动画结束后）。曾经「await showDialog 返回即 dispose」会在退场
/// 动画帧触碰已销毁 controller——保存后宿主 setState 让仍在退场的 TextField
/// 重建 addListener 直接断言崩（widget 测试实测复现）。
///
/// BUG-1075：输入框带单位后缀、近 7 日日均参考值、一排快捷预设 chip。保存 pop
/// [StatGoalEditResult]，取消 pop null。
class StatGoalEditDialog extends StatefulWidget {
  const StatGoalEditDialog({
    required this.initialDailyChars,
    this.recentDailyAverage = 0,
    super.key,
  });

  /// 当前每日目标（0 = 未设，输入框留空）。
  final int initialDailyChars;

  /// 近 7 日日均字数（全来源合计，与目标同口径）；<=0 不显示参考行。
  final int recentDailyAverage;

  /// 每日目标快捷预设（字/天）：点一下直接填进输入框，省得用户凭空想数字。
  static const List<int> presets = <int>[3000, 5000, 10000, 20000];

  @override
  State<StatGoalEditDialog> createState() => _StatGoalEditDialogState();
}

class _StatGoalEditDialogState extends State<StatGoalEditDialog> {
  late final TextEditingController _daily = TextEditingController(
    text: _initialText(widget.initialDailyChars),
  );

  static String _initialText(int chars) =>
      chars <= 0 ? '' : chars.toString();

  static int _parse(TextEditingController c) {
    final int value = int.tryParse(c.text.trim()) ?? 0;
    return value < 0 ? 0 : value;
  }

  @override
  void initState() {
    super.initState();
    // 预设按钮组的选中态跟随输入框（手输 5000 也点亮「5000」那一格）。
    _daily.addListener(_onDailyChanged);
  }

  void _onDailyChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _daily.removeListener(_onDailyChanged);
    _daily.dispose();
    super.dispose();
  }

  /// 预设 / 近 7 日日均 → 填入每日输入框（光标置尾，用户可继续改）。
  void _applyPreset(int chars) {
    final String text = chars.toString();
    _daily.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// 2026-10 M3E 重做（用户反馈「这个设定目标的界面没有经历过 ai 的洗礼」）：
  /// 旧版是两个裸下划线输入框 + 一排散落的纯文字预设，层级全靠缩进。现在：
  /// - 顶部 M3E 饼干形 hero 图标（旗子）+ 标题；
  /// - 每日目标是大号填充输入框（数字用 headline 字号，单位后缀），是这张卡的主角；
  /// - 近 7 日日均变成一颗可点的建议 chip（点一下直接填进去），不再是一行灰字；
  /// - 快捷预设是 M3E 连接按钮组（单选，选中态随输入框联动，弹簧切换）；
  /// - 每周目标是次要的填充输入框；
  /// - 动作区「取消」文字按钮 +「保存」实心主按钮。
  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final int daily = _parse(_daily);
    final int average = widget.recentDailyAverage;
    // 填充色要和对话框底色拉开（主题默认填充色与 M3 对话框容器几乎同色）。
    final Color fill = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.08),
      theme.colorScheme.surface,
    );
    InputDecoration filled({required String label}) => InputDecoration(
          labelText: label,
          suffixText: t.stat_goal_unit_chars,
          suffixStyle: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          filled: true,
          fillColor: fill,
          border: OutlineInputBorder(
            borderRadius: tokens.radii.cardRadius,
            borderSide: BorderSide.none,
          ),
        );
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.flag,
        tone: FushiHeroTone.primary,
      ),
      title: Text(t.stat_goal_set),
      // 内容可能变高：横屏/小窗下用滚动兜底，不再顶到溢出。
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              FushiTextFieldControl(
                key: const ValueKey<String>('stat-goal-daily-field'),
                controller: _daily,
                keyboardType: TextInputType.number,
                style: (theme.textTheme.headlineSmall ??
                        tokens.type.listTitle)
                    .copyWith(fontWeight: FontWeight.w700),
                decoration: filled(label: t.stat_goal_daily),
              ),
              if (average > 0) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FushiActionChipControl(
                    key: const ValueKey<String>('stat-goal-average-chip'),
                    avatar: const FushiIcon(FushiIcons.trendingUp, size: 18),
                    label: Text(t.stat_goal_recent_average(n: average)),
                    onPressed: () => _applyPreset(average),
                  ),
                ),
              ],
              SizedBox(height: tokens.spacing.card),
              Text(
                t.stat_goal_presets,
                style: context.fushiType.titleSmallEmphasized,
              ),
              SizedBox(height: tokens.spacing.gap),
              FushiConnectedButtonGroup<int>(
                key: const ValueKey<String>('stat-goal-presets'),
                showSelectedIcon: false,
                emptySelectionAllowed: true,
                expandedInsets: EdgeInsets.zero,
                segments: <ButtonSegment<int>>[
                  for (final int preset in StatGoalEditDialog.presets)
                    ButtonSegment<int>(
                      value: preset,
                      label: Text(formatStatCharsAxis(preset)),
                    ),
                ],
                selected: StatGoalEditDialog.presets.contains(daily)
                    ? <int>{daily}
                    : const <int>{},
                onSelectionChanged: (Set<int> picked) {
                  if (picked.isNotEmpty) _applyPreset(picked.first);
                },
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.cancel),
        ),
        FushiFilledButton(
          key: const ValueKey<String>('stat-goal-save'),
          onPressed: () => Navigator.of(context).pop<StatGoalEditResult>(
            (daily: _parse(_daily)),
          ),
          child: Text(t.dialog_save),
        ),
      ],
    );
  }
}

/// 统计页字数外显：数字部分走当前语言的紧凑写法（[formatCompactCount]：CJK
/// `6.8万`、其余语言 `68K`），再套上 i18n 的「N characters」文案。
///
/// 倍率单位不再进 i18n 词条——它是语言属性而非可翻译文案，旧的
/// `stat_format_chars_wan` 键把中文万进制硬贴给了 13 种非 CJK 语言（BUG-935）。
/// 全统计页只此一份实现（阅读页原私有 `_formatChars` 已并入）。
String formatStatChars(int chars) =>
    t.stat_format_chars(n: formatStatCharsAxis(chars));

/// 阅读速度外显：四舍五入到整数字/小时，套 i18n 单位文案（`N 字/时`）。时段卡、
/// 会话行、按书行都经这一处（用户 2026-09-12：统计中心顶部方框与每个会话都要
/// 显示「每小时多少字」）。
String formatStatCph(double cph) =>
    t.stat_speed_cph(n: cph.round().toString());

/// 一组事实行 / 一次会话的阅读速度外显：经 [computeCph]（最小样本 1 分钟，
/// BUG-1107）算不出有效速度时返回 null，调用方不显示该行而不是显示 0。
String? formatStatCphOf(int chars, int ms) {
  if (chars <= 0) return null;
  final double? cph = computeCph(chars, ms);
  return cph == null ? null : formatStatCph(cph);
}

/// 一个时段（[contains] 选 dateKey）内**阅读域**的速度外显：只累加 `isBook` 的
/// 日面行再经 [formatStatCphOf]。统计中心总览的时段卡是跨域总和（视频只计时不
/// 计字、游戏 hook 只计字不计时），「字/时」只对阅读域有意义，所以单独切片算。
String? statBookCphOf(
  List<StatFact> daily,
  bool Function(String dateKey) contains,
) {
  int chars = 0;
  int ms = 0;
  for (final StatFact f in daily) {
    if (!f.isBook || !contains(f.dateKey)) continue;
    chars += f.chars;
    ms += f.ms;
  }
  return formatStatCphOf(chars, ms);
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

/// 「今日按小时」单色柱状图区块（视频统计用：观看时长没有阅读面之分，只有一带）。
/// [hourlyMs] 为 0-23 每小时的毫秒值。
Widget buildStatHourlyChartSection(BuildContext context, List<int> hourlyMs) {
  final StatChartColors chartColors = statChartColorsOf(context);
  return _buildStatHourlyChartSection(
    context,
    bands: <StatHourlyBand>[
      StatHourlyBand(values: hourlyMs, color: chartColors.compare),
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
  final StatChartColors chartColors = statChartColorsOf(context);
  final List<StatHourlyFormatBand> active = breakdown.activeBands;
  return _buildStatHourlyChartSection(
    context,
    bands: <StatHourlyBand>[
      for (final StatHourlyFormatBand band in active)
        StatHourlyBand(
          values: breakdown.valuesOf(band),
          color: statHourlyBandColor(band, chartColors),
        ),
    ],
    legendBands: statHourlyLegendBands(active),
    showUnattributedNote: active.contains(StatHourlyFormatBand.unattributed),
  );
}

/// 统计图表的系列配色：两套设计系统各取各的语义色，图表代码只问角色不问色值。
///
/// 为什么不直接读 [ColorScheme]：Apple 设计系统下 `primary` 与 `secondary` 都是
/// 强调色（默认单色主题是黑 / 白）、`tertiary` 是 systemOrange——按 MD3 的
/// primary / secondary / tertiary 分三类，PDF 与漫画两带会画成同一个颜色。
/// Apple 这边按「健康 / 屏幕使用时间」的做法：主系列用强调色，其余类别用
/// 系统色（orange / teal），升降与达标用 systemGreen / systemRed。
@immutable
class StatChartColors {
  const StatChartColors({
    required this.series,
    required this.compare,
    required this.third,
    required this.neutral,
    required this.up,
    required this.down,
    required this.reached,
  });

  /// MD3：colorScheme 色阶（primary / tertiary / secondary）。
  factory StatChartColors.material(ColorScheme scheme) => StatChartColors(
    series: scheme.primary,
    compare: scheme.tertiary,
    third: scheme.secondary,
    neutral: scheme.outlineVariant,
    up: scheme.primary,
    down: scheme.error,
    reached: scheme.tertiary,
  );

  /// Apple：强调色 + 系统色（HIG UIKit 动态色 light / dark 两档）。
  factory StatChartColors.apple(FushiAppleColors apple, Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    return StatChartColors(
      series: apple.accent,
      compare: apple.warning,
      // systemTeal：与 orange、强调色（单色 / 蓝紫系）都拉得开。
      third: dark ? const Color(0xFF40C8E0) : const Color(0xFF30B0C7),
      neutral: apple.opaqueSeparator,
      up: apple.success,
      down: apple.destructive,
      reached: apple.success,
    );
  }

  /// 主系列（柱 / 主线 / 第一类）。
  final Color series;

  /// 对比系列（均值线、第二类）。
  final Color compare;

  /// 第三类。
  final Color third;

  /// 不归任何一类的中性带（未区分历史）。
  final Color neutral;

  /// 环比上升。
  final Color up;

  /// 环比下降 / 异常点。
  final Color down;

  /// 目标已达成。
  final Color reached;
}

/// 当前设计系统的统计图表配色。
StatChartColors statChartColorsOf(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return isGlassDesign(context)
      ? StatChartColors.apple(appleColorsOf(context), theme.brightness)
      : StatChartColors.material(theme.colorScheme);
}

/// 热力图空格的（填充, 描边）。
///
/// MD3：overlay 面色 + outline 描边兜底（BUG-1276：自定义主题会把 surface 色阶
/// 压得与卡底过近）。Apple：卡底恒是实色 secondarySystemGroupedBackground，空格用
/// systemFill 就和卡底拉得开，不再描边——Apple 的格子图（「健身」月历、屏幕
/// 使用时间）都是无边灰格。
(Color, Color?) statHeatmapEmptyColors(BuildContext context) {
  if (isGlassDesign(context)) return (appleColorsOf(context).fill, null);
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  return (tokens.surfaces.overlay, tokens.surfaces.outline);
}

/// 分带填充色。
///
/// 未区分历史刻意用中性色，而不是第四个品类色：它不是一种书，配一个和
/// EPUB / PDF / 漫画平级的彩色只会让人以为它也是某一类。
Color statHourlyBandColor(StatHourlyFormatBand band, StatChartColors colors) =>
    switch (band) {
      StatHourlyFormatBand.epub => colors.compare,
      StatHourlyFormatBand.pdf => colors.series,
      StatHourlyFormatBand.manga => colors.third,
      StatHourlyFormatBand.unattributed => colors.neutral,
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
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final ColorScheme colorScheme = Theme.of(context).colorScheme;
  // 2026-10 统计中心重设计：与范围时长图同一张区块卡外框（[StatSectionCard]）。
  return StatSectionCard(
    title: t.stat_today_hourly,
    icon: Icons.schedule_outlined,
    margin: EdgeInsets.fromLTRB(
      tokens.spacing.card,
      0,
      tokens.spacing.card,
      tokens.spacing.card,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
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
            color: statHourlyBandColor(band, statChartColorsOf(context)),
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

/// 统计 sheet（时段明细 / 会话列表）的高度上限占屏高比例。
const double kStatSheetMaxHeightFactor = 0.8;

/// 统计明细面（时段明细 / 会话列表）的唯一弹出入口：移动端是底部 sheet，桌面端
/// （Windows / macOS / Linux）是居中对话框。
///
/// 桌面上宽窗口底部弹一条抽屉很别扭（用户 2026-09-28「Windows 这里用抽屉有点怪」）：
/// 内容挤在屏幕下半截、要往下看、拖动条对鼠标没意义。对话框限宽 640、限高
/// [kStatSheetMaxHeightFactor]，点外面 / Esc / 右上角关闭都会收起；[builder] 的内容
/// 不区分载体（条目里 `Navigator.pop` 收的是同一个 modal route）。
Future<void> showStatDetailSurface(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  if (!FushiAppUiScale.isDesktopPlatform(Theme.of(context).platform)) {
    return adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) =>
          statSheetHeightCap(sheetContext, child: builder(sheetContext)),
    );
  }
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) {
      final FushiDesignTokens tokens = FushiDesignTokens.of(dialogContext);
      return FushiDialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: kStatDetailDialogMaxWidth,
            maxHeight:
                MediaQuery.sizeOf(dialogContext).height *
                kStatSheetMaxHeightFactor,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.only(
                  top: tokens.spacing.gap / 2,
                  right: tokens.spacing.gap / 2,
                ),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FushiIconButton(
                    icon: Icons.close,
                    tooltip: MaterialLocalizations.of(
                      dialogContext,
                    ).closeButtonTooltip,
                    onTap: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
              ),
              Flexible(child: builder(dialogContext)),
            ],
          ),
        ),
      );
    },
  );
}

/// 桌面端统计明细对话框的最大宽度（逻辑像素）。
const double kStatDetailDialogMaxWidth = 640;

/// 给统计 sheet 的内容加高度上限。
///
/// [adaptiveModalSheet] 走 `isScrollControlled: true`、不开 `useSafeArea`：sheet 高度
/// 只受内容约束，路由还会抹掉顶部安全区。时段 / 会话一多，sheet 就一路长到屏幕
/// 最顶，拖动条压进状态栏 / 灵动岛下面（iOS 刘海屏最明显），既盖满页面又难以下拉
/// 收起。内容少时照常按内容高度收缩，只在超出时截到 [kStatSheetMaxHeightFactor]
/// 并在 sheet 内滚动。
Widget statSheetHeightCap(BuildContext context, {required Widget child}) {
  return ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * kStatSheetMaxHeightFactor,
    ),
    child: child,
  );
}
