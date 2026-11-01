/// 首页 dashboard 的展示件（2026-10 精简重设计；10-10 加回分区标题与「继续」主角卡）：
/// 学习头部行（目标环 + 今日字数 + 今日时长）、「继续」主角卡（M3E 波浪进度条 +
/// 「继续阅读 / 继续观看」主按钮）、带标题的封面卡、「最近添加」紧凑行、每日目标环、
/// 空态与首载骨架块。
///
/// 只放**纯展示**的组件——取数、筛选、打开路径都留在
/// `home_dashboard_page.dart` 的 state 里（那边有一批按源码锚点钉住的守卫）。
/// 这里的组件只吃算好的值与回调，两套设计系统（MD3 Expressive / Apple）与
/// 墨水屏的差异也在这里各自收口。
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 首载骨架块：中性底色圆角块（MD3 surfaceContainer 档 / Apple tertiaryFill /
/// 墨水屏描边），尺寸即最终内容的大致轮廓，数据到达时整块换成真实内容——
/// 首帧就有版式，不再先闪一圈菊花或「暂无内容」再跳成真数据。
///
/// M3E（2026-10-05）：块本身是 [FushiSkeleton]（surfaceContainerHighest 色块），
/// 成组骨架外包一层 [FushiSkeletonShimmer]，光带一次扫过整组；闪光**有界**
/// （扫三轮就停），不会像常驻动画那样把之后每一帧都拖进重绘。
class HomeSkeletonBlock extends StatelessWidget {
  const HomeSkeletonBlock({
    super.key,
    this.width,
    required this.height,
    this.radius,
  });

  final double? width;
  final double height;
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) {
    return FushiSkeleton(width: width, height: height, borderRadius: radius);
  }
}

/// 首页「学习 + 继续」卡封面行的首载骨架：一排与真实封面同高的竖块。
class HomeContinueRowSkeleton extends StatelessWidget {
  const HomeContinueRowSkeleton({super.key, this.coverHeight = 148});

  final double coverHeight;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiSkeletonShimmer(
      child: SizedBox(
        key: const ValueKey<String>('home-continue-skeleton'),
        height: coverHeight,
        child: ClipRect(
          child: OverflowBox(
            alignment: AlignmentDirectional.centerStart,
            maxWidth: double.infinity,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int i = 0; i < 6; i++) ...<Widget>[
                  if (i > 0) SizedBox(width: tokens.spacing.gap),
                  HomeSkeletonBlock(
                    width: coverHeight * 0.7,
                    height: coverHeight,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 学习卡头部目标行的首载骨架（目标环 + 两行文字条）。
class HomeGoalSkeleton extends StatelessWidget {
  const HomeGoalSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      key: const ValueKey<String>('home-goal-skeleton'),
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: Row(
        children: <Widget>[
          const FushiSkeleton(width: 48, height: 48, circle: true),
          SizedBox(width: tokens.spacing.card),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const HomeSkeletonBlock(width: 64, height: 12),
                SizedBox(height: tokens.spacing.gap / 2),
                const FractionallySizedBox(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: 0.6,
                  child: HomeSkeletonBlock(height: 16),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 首页各分区统一的空状态：中性圆底图标 + 一行说明，左对齐贴分区内容区。
///
/// 此前「继续」/「活动」的空态是一行裸灰字，与库页的空态件风格脱节，
/// 而「继续」在日文 UI 下还漏了翻译（BUG-2966）。两处收成同一个件，
/// 新增分区的空态也走这里。
class HomeEmptyState extends StatelessWidget {
  const HomeEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.actions = const <Widget>[],
    this.stateKey = 'home-empty-state',
  });

  final IconData icon;
  final String message;

  /// 外层 Padding 的 key（测试定位用）。同一屏有两处说明块（「继续」空态 +
  /// 新手引导卡）时各用各的，避免按 key 查找命中两个。
  final String stateKey;

  /// 说明下方的引导按钮（新用户空库：去书架 / 去媒体库）；空 = 只有说明。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget row = Row(
      children: <Widget>[
        SizedBox.square(
          dimension: 40,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fushiNeutralBlockColor(context),
              border: isEinkTheme(context)
                  ? Border.all(color: tokens.surfaces.outline)
                  : null,
            ),
            child: Center(
              child: FushiIcon(
                icon,
                size: 20,
                color: tokens.type.metadata.color,
              ),
            ),
          ),
        ),
        SizedBox(width: tokens.spacing.card),
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.metadata,
          ),
        ),
      ],
    );
    return Padding(
      key: ValueKey<String>(stateKey),
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: actions.isEmpty
          ? row
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                row,
                SizedBox(height: tokens.spacing.gap),
                Padding(
                  // 与说明文字左缘对齐（图标 40 + 间距）。
                  padding: EdgeInsetsDirectional.only(
                    start: 40 + tokens.spacing.card,
                  ),
                  child: Wrap(
                    spacing: tokens.spacing.gap,
                    runSpacing: tokens.spacing.gap / 2,
                    children: actions,
                  ),
                ),
              ],
            ),
    );
  }
}

/// 首页「新手引导」卡是否出现：没点过「不再显示」，且（新手引导没走完，或
/// 本地库还是空的）。[libraryEmpty] 只在首载结束后才有意义，调用方自己把关。
bool homeOnboardingCardVisible({
  required bool dismissed,
  required bool onboardingFinished,
  required bool libraryEmpty,
}) => !dismissed && (!onboardingFinished || libraryEmpty);

/// 每日目标环：今日学习字数 / 目标的环形进度（MD3 Expressive 波浪环 / Apple
/// 原生环，分派在 [FushiCircularProgressIndicator] 里）。未设目标时环里放一面
/// 旗子，表示「这里可以设一个」。
///
/// 进度变化（首载 / 写库后重载 / 改目标）走一段 M3E 弹簧补间从旧值长到新值，
/// 墨水屏与「减弱动态效果」下 [fushiMotionDuration] 归零即瞬间到位。
class HomeGoalRing extends StatelessWidget {
  const HomeGoalRing({super.key, required this.fraction, this.size = 56});

  /// 0..1；null = 未设目标。
  final double? fraction;
  final double size;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double? target = fraction;
    final Color accent = tokens.surfaces.primary;
    if (target == null) {
      return SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fushiNeutralBlockColor(context),
            border: isEinkTheme(context)
                ? Border.all(color: tokens.surfaces.outline)
                : null,
          ),
          child: Center(
            child: FushiIcon(FushiIcons.flag, size: 22, color: accent),
          ),
        ),
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: target.clamp(0.0, 1.0)),
      duration: fushiMotionDuration(context, FushiMotion.long),
      curve: FushiMotion.enter,
      builder: (BuildContext context, double value, Widget? _) =>
          SizedBox.square(
            dimension: size,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                SizedBox.square(
                  dimension: size,
                  child: FushiCircularProgressIndicator(
                    value: value,
                    strokeWidth: 5,
                    color: accent,
                    backgroundColor: fushiNeutralBlockColor(context),
                  ),
                ),
                Text(
                  '${(value * 100).round()}%',
                  style: context.fushiType.labelSmall.copyWith(
                    fontWeight: FontWeight.w600,
                    color: tokens.surfaces.onSurface,
                  ),
                ),
              ],
            ),
          ),
    );
  }
}

/// 首页顶部的学习头部行（2026-10 精简：原「学习活动」卡并进「继续」卡顶部）。
///
/// 只有数字，不挂「每日目标」「今日时长」之类的小字标签（用户反馈「看一眼就
/// 知道了」）：左 = 目标环，中 = 今日字数（设了目标时是「X / Y 字」），右 =
/// 时钟图标 + 今日学习时长，三者恒在同一行。窄屏放不下时字数等比缩小，**不折行、
/// 不省略号截断**任何数字（群反馈「打开主界面时学习统计要完整显示」）。
///
/// 已设目标：整行即「改目标」入口；未设：行本身不占焦点，右侧给「设定目标」按钮。
class HomeStudyHeader extends StatelessWidget {
  const HomeStudyHeader({
    super.key,
    required this.fraction,
    required this.value,
    required this.todayTime,
    required this.todayTimeSemanticLabel,
    required this.onEditGoal,
    this.setGoalLabel,
  });

  /// 目标进度 0..1；null = 未设目标（环里画旗子）。
  final double? fraction;

  /// 今日字数文案（已格式化）。
  final String value;

  /// 今日学习时长文案（已格式化）。
  final String todayTime;

  /// 时长块的读屏标签（屏上只有图标 + 数字，读屏要说清是什么）。
  final String todayTimeSemanticLabel;
  final VoidCallback onEditGoal;

  /// 非空 = 未设目标，右侧显示这颗「设定目标」按钮。
  final String? setGoalLabel;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool hasGoal = setGoalLabel == null;
    final Duration swap = fushiMotionDuration(context, FushiMotion.short);
    final Widget valueText = AnimatedSwitcher(
      duration: swap,
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      child: Text(
        value,
        key: ValueKey<String>(value),
        maxLines: 1,
        softWrap: false,
        style: (theme.textTheme.titleLarge ?? tokens.type.listTitle).copyWith(
          color: tokens.surfaces.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    final Color timeColor =
        tokens.type.metadata.color ?? tokens.surfaces.onSurface;
    final Widget time = Semantics(
      key: const ValueKey<String>('home-today-time'),
      container: true,
      label: todayTimeSemanticLabel,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(FushiIcons.schedule, size: 20, color: timeColor),
          SizedBox(width: tokens.spacing.gap / 2),
          AnimatedSwitcher(
            duration: swap,
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            child: Text(
              todayTime,
              key: ValueKey<String>(todayTime),
              maxLines: 1,
              softWrap: false,
              style: (theme.textTheme.titleMedium ?? tokens.type.listTitle)
                  .copyWith(
                    color: tokens.surfaces.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
    final String? setLabel = setGoalLabel;
    final Widget trailingRow = setLabel == null
        ? time
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              time,
              SizedBox(width: tokens.spacing.gap),
              FushiTextButton(onPressed: onEditGoal, child: Text(setLabel)),
            ],
          );
    return InkWell(
      key: const ValueKey<String>('home-goal-row'),
      onTap: hasGoal ? onEditGoal : null,
      canRequestFocus: hasGoal,
      borderRadius: FushiBorderRadius.card,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
        child: Row(
          children: <Widget>[
            HomeGoalRing(fraction: fraction, size: 52),
            SizedBox(width: tokens.spacing.card),
            // 字数与时长恒在同一行（用户：「每日目标的同一行右侧加上今日时长」）：
            // 放得下时两端对齐（时长贴右）；极窄屏（320）放不下时整行等比缩小，
            // 两个数字一起缩，不折行、不省略号截断、也不会只把其中一个压成小字。
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) => FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: c.maxWidth),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        valueText,
                        SizedBox(width: tokens.spacing.card),
                        trailingRow,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「继续」竖封面的比例（宽 / 高）：游戏是卡盒材质的 1:1.6
/// （[kShelfGameCaseAspectRatio]，与游戏库同形），书 / 视频海报 2:3。
double homeContinuePortraitAspect(ShelfCoverMaterial? material) =>
    material == ShelfCoverMaterial.gameCase ? kShelfGameCaseAspectRatio : 2 / 3;

/// 首页面板自适应分列（用户 2026-10-31「有空地的时候可以自适应一下这些面板」；
/// 2026-11-01「宽屏下首页有点空，最好就是自适应」）：
///
/// - 列数上限 = 按 [minColumnWidth] 放得下几列，且不超过面板数与 [maxColumns]
///   （[columnsFor]）。
/// - 按真实高度排：在 2..上限 列里逐个试，每种列数下先量出各面板高度，按「最高的
///   先放进当前最矮的列」分配，选列底参差（空白）占比最小的那种。一个很长的面板
///   （最近添加）独占一列、几条矮面板（复习 / AI 助手）叠在另一列，不再出现某列
///   只有一条矮面板、下面一大片空。
/// - 列内保持面板原顺序；含第一个面板（今日）的列排在最前。
class HomePanelFlow extends MultiChildRenderObjectWidget {
  const HomePanelFlow({
    super.key,
    required super.children,
    required this.gap,
    this.minColumnWidth = 320,
    this.maxColumns = 3,
  });

  final double gap;
  final double minColumnWidth;
  final int maxColumns;

  /// 宽 [width] 下 [count] 个面板最多分几列（纯函数，测试与版面共用）。
  static int columnsFor({
    required double width,
    required int count,
    required double gap,
    double minColumnWidth = 320,
    int maxColumns = 3,
  }) {
    if (count <= 1) return 1;
    final int fit = ((width + gap) / (minColumnWidth + gap)).floor();
    return fit.clamp(1, math.min(count, maxColumns));
  }

  /// 按高度给 [heights] 分 [columns] 列：最高的先放进当前最矮的列；返回每列的
  /// 面板序号（列内按原顺序）与各列总高（含 [gap]）。纯函数，测试可直接验。
  static ({List<List<int>> columns, List<double> heights}) balance(
    List<double> heights,
    int columns,
    double gap,
  ) {
    final List<List<int>> cols = <List<int>>[
      for (int c = 0; c < columns; c++) <int>[],
    ];
    final List<double> totals = List<double>.filled(columns, 0);
    final List<int> order = List<int>.generate(heights.length, (int i) => i)
      ..sort((int a, int b) {
        final int byHeight = heights[b].compareTo(heights[a]);
        return byHeight != 0 ? byHeight : a.compareTo(b);
      });
    for (final int i in order) {
      int shortest = 0;
      for (int c = 1; c < columns; c++) {
        if (totals[c] < totals[shortest]) shortest = c;
      }
      totals[shortest] += (cols[shortest].isEmpty ? 0 : gap) + heights[i];
      cols[shortest].add(i);
    }
    for (final List<int> col in cols) {
      col.sort();
    }
    // 含第一个面板的列排最前，其余按各自首个面板的顺序。
    final List<int> colOrder = List<int>.generate(columns, (int c) => c)
      ..removeWhere((int c) => cols[c].isEmpty)
      ..sort((int a, int b) => cols[a].first.compareTo(cols[b].first));
    return (
      columns: <List<int>>[for (final int c in colOrder) cols[c]],
      heights: <double>[for (final int c in colOrder) totals[c]],
    );
  }

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPanelFlow(
    gap: gap,
    minColumnWidth: minColumnWidth,
    maxColumns: maxColumns,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderPanelFlow renderObject) {
    renderObject
      ..gap = gap
      ..minColumnWidth = minColumnWidth
      ..maxColumns = maxColumns;
  }
}

class _PanelFlowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPanelFlow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PanelFlowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PanelFlowParentData> {
  _RenderPanelFlow({
    required double gap,
    required double minColumnWidth,
    required int maxColumns,
  }) : _gap = gap,
       _minColumnWidth = minColumnWidth,
       _maxColumns = maxColumns;

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  double _minColumnWidth;
  set minColumnWidth(double v) {
    if (v == _minColumnWidth) return;
    _minColumnWidth = v;
    markNeedsLayout();
  }

  int _maxColumns;
  set maxColumns(int v) {
    if (v == _maxColumns) return;
    _maxColumns = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PanelFlowParentData) {
      child.parentData = _PanelFlowParentData();
    }
  }

  List<RenderBox> get _kids {
    final List<RenderBox> out = <RenderBox>[];
    RenderBox? child = firstChild;
    while (child != null) {
      out.add(child);
      child = childAfter(child);
    }
    return out;
  }

  double _columnWidth(double width, int columns) =>
      (width - _gap * (columns - 1)) / columns;

  /// 按列宽真排一遍量高度（面板里有 LayoutBuilder，不支持 dry layout）；
  /// performLayout 末尾会按选定列宽再排一次，最后那次生效。
  List<double> _measure(List<RenderBox> kids, double colWidth) {
    final BoxConstraints c = BoxConstraints.tightFor(width: colWidth);
    return <double>[
      for (final RenderBox k in kids)
        (k..layout(c, parentUsesSize: true)).size.height,
    ];
  }

  @override
  void performLayout() {
    final List<RenderBox> kids = _kids;
    final double width = constraints.maxWidth;
    if (kids.isEmpty) {
      size = constraints.constrain(Size(width, 0));
      return;
    }
    final int maxCols = HomePanelFlow.columnsFor(
      width: width,
      count: kids.length,
      gap: _gap,
      minColumnWidth: _minColumnWidth,
      maxColumns: _maxColumns,
    );
    int best = 1;
    double bestWaste = double.infinity;
    // 单列恒为零空白，不参与比较；放得下两列以上时才挑。
    for (int cols = maxCols; cols >= 2; cols--) {
      final ({List<List<int>> columns, List<double> heights}) plan =
          HomePanelFlow.balance(
            _measure(kids, _columnWidth(width, cols)),
            cols,
            _gap,
          );
      final double tallest = plan.heights.fold<double>(0, math.max);
      if (tallest <= 0) continue;
      final double filled = plan.heights.fold<double>(
        0,
        (double a, double h) => a + h,
      );
      final double waste = 1 - filled / (tallest * cols);
      // 空白差不多时偏向更多列（更矮）。
      if (waste < bestWaste - 0.05) {
        best = cols;
        bestWaste = waste;
      }
    }
    final double colWidth = _columnWidth(width, best);
    final BoxConstraints childConstraints = BoxConstraints.tightFor(
      width: colWidth,
    );
    for (final RenderBox k in kids) {
      k.layout(childConstraints, parentUsesSize: true);
    }
    final ({List<List<int>> columns, List<double> heights}) plan =
        HomePanelFlow.balance(
          <double>[for (final RenderBox k in kids) k.size.height],
          best,
          _gap,
        );
    double height = 0;
    for (int c = 0; c < plan.columns.length; c++) {
      double y = 0;
      for (final int i in plan.columns[c]) {
        final _PanelFlowParentData pd =
            kids[i].parentData! as _PanelFlowParentData;
        pd.offset = Offset(c * (colWidth + _gap), y);
        y += kids[i].size.height + _gap;
      }
      height = math.max(height, y - _gap);
    }
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// 「今日」面板宽屏时的近 7 天柱条（2026-10-31 方案 A 补齐「今日」）：每天一根，
/// 高度按 7 天里的最大值归一，今天用强调色、其余用浅一档；悬停提示是当天字数。
/// 全为 0 时柱条贴底一线（不画空白）。
class HomeWeekBars extends StatelessWidget {
  const HomeWeekBars({
    super.key,
    required this.values,
    required this.labels,
    required this.semanticLabel,
    this.height = 44,
  });

  /// 升序 7 天的数值（最后一个是今天）。
  final List<int> values;

  /// 与 [values] 对齐的悬停提示文案。
  final List<String> labels;
  final String semanticLabel;
  final double height;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final Color today = eink
        ? cs.onSurface
        : (apple ? appleColorsOf(context).accent : cs.primary);
    final Color past = eink
        ? cs.outline
        : (apple
              ? appleColorsOf(context).accent.withValues(alpha: 0.4)
              : cs.primaryContainer);
    final int peak = values.fold<int>(0, math.max);
    return Semantics(
      container: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: SizedBox(
        key: const ValueKey<String>('home-week-bars'),
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            for (int i = 0; i < values.length; i++) ...<Widget>[
              if (i > 0) SizedBox(width: tokens.spacing.gap / 2),
              Expanded(
                child: FushiTooltip(
                  message: labels[i],
                  excludeFromSemantics: true,
                  child: TweenAnimationBuilder<double>(
                    // begin: 0：首次出现也从底长起（只给 end 时首帧直接画终值）。
                    tween: Tween<double>(
                      begin: 0,
                      end: peak == 0 ? 0 : values[i] / peak,
                    ),
                    duration: fushiMotionDuration(context, FushiMotion.medium),
                    curve: FushiMotion.standard,
                    builder: (BuildContext _, double f, Widget? __) =>
                        Container(
                          height: math.max(3, height * f),
                          decoration: BoxDecoration(
                            color: i == values.length - 1 ? today : past,
                            borderRadius: const BorderRadius.all(
                              Radius.circular(4),
                            ),
                          ),
                        ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 「最近添加」紧凑行（2026-10-10，横屏 / 宽屏侧栏）：小竖封面 + 标题 + 「类型 ·
/// 相对时间」一行。侧栏宽度有限，列表比横滑封面行省地方，标题也能完整露出。
class HomeRecentTile extends StatelessWidget {
  const HomeRecentTile({
    super.key,
    required this.cover,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.coverHeight = 60,
    this.material,
  });

  final Widget cover;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final double coverHeight;

  /// 小缩略图的条目材质（按条目种类给，走简化档 [ShelfCoverDensity.compact]）；
  /// null = 不套材质。
  final ShelfCoverMaterial? material;

  /// 列表行缩略图：材质简化档（圆角 / 内描边 / 轻光泽，没有投影与扫光）。
  Widget _thumb() {
    final Widget frame = ShelfCoverFrame(
      density: ShelfCoverDensity.compact,
      child: cover,
    );
    final ShelfCoverMaterial? m = material;
    return m == null
        ? frame
        : ShelfCoverMaterialScope(material: m, child: frame);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiPressScale(
      child: Semantics(
        container: true,
        button: true,
        label: '$title · $subtitle',
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: FushiBorderRadius.card,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: coverHeight * homeContinuePortraitAspect(material),
                  height: coverHeight,
                  child: _thumb(),
                ),
                SizedBox(width: tokens.spacing.card),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.type.listTitle,
                      ),
                      SizedBox(height: tokens.spacing.gap / 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.type.metadata,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
