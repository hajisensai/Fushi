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

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_poster_block.dart'
    show FushiBarReferenceLine;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';

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
    // Apple：强调色环 + systemFill 底轨、环心 label（不取 M3E primary / 中性块色）。
    final FushiAppleColors? apple =
        isGlassDesign(context) && !isEinkTheme(context)
        ? appleColorsOf(context)
        : null;
    final Color accent = apple?.accent ?? tokens.surfaces.primary;
    final Color track = apple?.fill ?? fushiNeutralBlockColor(context);
    if (target == null) {
      return SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: track,
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
                    // 墨水屏的中性块色是纯白：底轨看不见，环只剩半截弧。用浅灰
                    // （前景 30%，与「语言目标」环同一个）。
                    backgroundColor: isEinkTheme(context)
                        ? tokens.surfaces.onSurface.withValues(alpha: 0.3)
                        : track,
                    // 铺满 [size]：不给外框时 M3E 指示器按默认 40 画在 52 的槽里，
                    // 环心只剩 ~22 宽，「37%」压在弧上（2026-11-20 走查截图）。
                    constraints: BoxConstraints.tight(Size.square(size)),
                    padding: EdgeInsets.zero,
                  ),
                ),
                // 达成后环心是对勾（与目标环 [StudyGoalRing] 同一完成状态）。
                if (target >= 1)
                  FushiIcon(FushiIcons.check, size: size * 0.42, color: accent)
                else
                  Text(
                    '${(value * 100).round()}%',
                    style: context.fushiType.labelSmall.copyWith(
                      fontWeight: FontWeight.w600,
                      color: apple?.label ?? tokens.surfaces.onSurface,
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
    // Apple：文字 label / secondaryLabel，整行点按走系统高亮（不画墨水）。
    final FushiAppleColors? apple =
        isGlassDesign(context) && !isEinkTheme(context)
        ? appleColorsOf(context)
        : null;
    final Color strong = apple?.label ?? tokens.surfaces.onSurface;
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
          color: strong,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    final Color timeColor =
        apple?.secondaryLabel ??
        tokens.type.metadata.color ??
        tokens.surfaces.onSurface;
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
                  .copyWith(color: strong, fontWeight: FontWeight.w600),
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
    final Widget row = Padding(
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
    );
    if (apple != null) {
      return FushiPlainButton(
        key: const ValueKey<String>('home-goal-row'),
        onPressed: hasGoal ? onEditGoal : null,
        borderRadius: BorderRadius.circular(
          FushiAppleMetrics.of(context).groupRadius / 2,
        ),
        child: row,
      );
    }
    return InkWell(
      key: const ValueKey<String>('home-goal-row'),
      onTap: hasGoal ? onEditGoal : null,
      canRequestFocus: hasGoal,
      borderRadius: FushiBorderRadius.card,
      child: row,
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

  /// 逐列数试排的次数（测试用：判据与面板高度都没变的 relayout 不该再试排）。
  @visibleForTesting
  static int debugColumnChoices = 0;

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

  /// 上次选列的判据（宽、面板数、gap / 最小列宽 / 最大列数）与选出的列数、
  /// 当时各面板在该列宽下的高度。判据与高度都没变时直接按缓存列数排一遍，不再
  /// 逐个列数试排——面板内部 relayout（数据到达、文字变化）尺寸没变就只排一次。
  Object? _choiceKey;
  int _chosenColumns = 1;
  List<double> _chosenHeights = const <double>[];

  /// 按列宽真排一遍量高度（面板里有 LayoutBuilder，不支持 dry layout）。
  List<double> _measure(List<RenderBox> kids, double colWidth) {
    final BoxConstraints c = BoxConstraints.tightFor(width: colWidth);
    return <double>[
      for (final RenderBox k in kids)
        (k..layout(c, parentUsesSize: true)).size.height,
    ];
  }

  static bool _sameHeights(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 0.5) return false;
    }
    return true;
  }

  /// 在 2..[maxCols] 列里逐个试排，选列底空白占比最小的；返回列数与该列宽下
  /// 各面板高度（子节点最后一次 layout 就停在选中的列宽上）。
  ({int columns, List<double> heights}) _chooseColumns(
    List<RenderBox> kids,
    double width,
    int maxCols,
  ) {
    HomePanelFlow.debugColumnChoices++;
    int best = 1;
    double bestWaste = double.infinity;
    List<double>? bestHeights;
    int? lastMeasured;
    // 单列恒为零空白，不参与比较；放得下两列以上时才挑。
    for (int cols = maxCols; cols >= 2; cols--) {
      final List<double> heights = _measure(kids, _columnWidth(width, cols));
      lastMeasured = cols;
      final ({List<List<int>> columns, List<double> heights}) plan =
          HomePanelFlow.balance(heights, cols, _gap);
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
        bestHeights = heights;
      }
    }
    if (best != lastMeasured || bestHeights == null) {
      bestHeights = _measure(kids, _columnWidth(width, best));
    }
    return (columns: best, heights: bestHeights);
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
    final Object key = (width, kids.length, _gap, _minColumnWidth, maxCols);
    int columns;
    List<double> heights;
    if (maxCols <= 1) {
      columns = 1;
      heights = _measure(kids, width);
    } else if (key == _choiceKey) {
      // 判据没变：按缓存列数排一遍；高度也没变就沿用，变了才重新试排。
      columns = _chosenColumns;
      heights = _measure(kids, _columnWidth(width, columns));
      if (!_sameHeights(heights, _chosenHeights)) {
        (columns: columns, heights: heights) = _chooseColumns(
          kids,
          width,
          maxCols,
        );
      }
    } else {
      (columns: columns, heights: heights) = _chooseColumns(
        kids,
        width,
        maxCols,
      );
    }
    _choiceKey = key;
    _chosenColumns = columns;
    _chosenHeights = heights;

    final double colWidth = _columnWidth(width, columns);
    final ({List<List<int>> columns, List<double> heights}) plan =
        HomePanelFlow.balance(heights, columns, _gap);
    double height = 0;
    for (int c = 0; c < plan.columns.length; c++) {
      double y = 0;
      for (final int i in plan.columns[c]) {
        final _PanelFlowParentData pd =
            kids[i].parentData! as _PanelFlowParentData;
        pd.offset = Offset(c * (colWidth + _gap), y);
        y += heights[i] + _gap;
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

/// 重设计外壳下首页色块面板的排布（设计稿首页 `.stat` 一排 `s2` 色块）：按行排，
/// 同一行的色块**等高**（按行里最高的那块拉齐），每行列数均分——
///
/// - 每行最多放得下几列 = 按 [minColumnWidth] 取整，且不超过 [maxColumns]；
/// - 行数 = 面板数 ÷ 每行上限向上取整，再把面板尽量均分到各行（[rowSizes]：
///   4 块排成 2 + 2 而不是 3 + 1，5 块排成 3 + 2），最后一行不会剩一块孤零零
///   挂在左边、右边一大片空；
/// - 窄屏（放不下两列）就是一列竖排。
///
/// 与 [HomePanelFlow]（按高度分列的瀑布流）不同：色块是一整块底色，列底参差
/// 会露出锯齿状的空白，所以这里按行拉齐。行内顺序 = 子节点顺序，Tab 与方向键
/// 走几何遍历。
class HomePosterRows extends MultiChildRenderObjectWidget {
  const HomePosterRows({
    super.key,
    required super.children,
    required this.gap,
    this.minColumnWidth = 300,
    this.maxColumns = 3,
  });

  final double gap;
  final double minColumnWidth;
  final int maxColumns;

  /// 宽 [width] 下 [count] 块面板逐行各放几块（纯函数，测试与版面共用）。
  static List<int> rowSizes({
    required double width,
    required int count,
    required double gap,
    double minColumnWidth = 300,
    int maxColumns = 3,
  }) {
    if (count <= 0) return const <int>[];
    final int fit = ((width + gap) / (minColumnWidth + gap)).floor().clamp(
      1,
      math.max(1, maxColumns),
    );
    final int rows = (count + fit - 1) ~/ fit;
    final int base = count ~/ rows;
    final int extra = count % rows;
    return <int>[for (int r = 0; r < rows; r++) base + (r < extra ? 1 : 0)];
  }

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPosterRows(
    gap: gap,
    minColumnWidth: minColumnWidth,
    maxColumns: maxColumns,
    textDirection: Directionality.of(context),
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPosterRows renderObject,
  ) {
    renderObject
      ..gap = gap
      ..minColumnWidth = minColumnWidth
      ..maxColumns = maxColumns
      ..textDirection = Directionality.of(context);
  }
}

class _PosterRowsParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPosterRows extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PosterRowsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PosterRowsParentData> {
  _RenderPosterRows({
    required double gap,
    required double minColumnWidth,
    required int maxColumns,
    required TextDirection textDirection,
  }) : _gap = gap,
       _minColumnWidth = minColumnWidth,
       _maxColumns = maxColumns,
       _textDirection = textDirection;

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

  TextDirection _textDirection;
  set textDirection(TextDirection v) {
    if (v == _textDirection) return;
    _textDirection = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PosterRowsParentData) {
      child.parentData = _PosterRowsParentData();
    }
  }

  @override
  void performLayout() {
    final List<RenderBox> kids = <RenderBox>[];
    RenderBox? child = firstChild;
    while (child != null) {
      kids.add(child);
      child = childAfter(child);
    }
    final double width = constraints.maxWidth;
    final List<int> rows = HomePosterRows.rowSizes(
      width: width,
      count: kids.length,
      gap: _gap,
      minColumnWidth: _minColumnWidth,
      maxColumns: _maxColumns,
    );
    final bool rtl = _textDirection == TextDirection.rtl;
    double y = 0;
    int next = 0;
    for (final int n in rows) {
      final double colWidth = (width - _gap * (n - 1)) / n;
      // 先按列宽量自然高度（面板里有 LayoutBuilder，不支持 dry layout），再按
      // 行里最高的那块统一定高重排一遍。
      double rowHeight = 0;
      for (int k = 0; k < n; k++) {
        final RenderBox kid = kids[next + k]
          ..layout(
            BoxConstraints.tightFor(width: colWidth),
            parentUsesSize: true,
          );
        rowHeight = math.max(rowHeight, kid.size.height);
      }
      for (int k = 0; k < n; k++) {
        final RenderBox kid = kids[next + k]
          ..layout(
            // 只抬到行高、不封顶：两遍量高都在「高度不设上限」下进行，面板里按
            // 约束分支的内容（LayoutBuilder、进场包装）两遍给出同一份版面。
            // 曾用紧约束重排：第二遍的内容比第一遍量出的高，整块在里面溢出。
            BoxConstraints(
              minWidth: colWidth,
              maxWidth: colWidth,
              minHeight: rowHeight,
            ),
            parentUsesSize: true,
          );
        final double x = k * (colWidth + _gap);
        (kid.parentData! as _PosterRowsParentData).offset = Offset(
          rtl ? width - x - colWidth : x,
          y,
        );
      }
      y += rowHeight + _gap;
      next += n;
    }
    size = constraints.constrain(
      Size(width, rows.isEmpty ? 0 : math.max(0, y - _gap)),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// [HomePosterRows] 里色块内容的竖排：同一行被拉到行高时，多出来的高度插在第
/// [split] 个子节点前面——前面的贴顶、从第 [split] 个起贴底，内容自然高度够了就是
/// 普通的 `Column(spacing: gap)`。
///
/// [HomePosterRows] 两遍量高都不封顶（只抬 minHeight），`Column` 的 [Spacer] /
/// [Expanded] 在不封顶的高度里用不了，所以单独写成按 minHeight 分配的竖排。
class HomePosterSpread extends MultiChildRenderObjectWidget {
  const HomePosterSpread({
    super.key,
    required super.children,
    required this.split,
    this.gap = 12,
  });

  /// 从这个下标起的子节点贴底；≥ 子节点数时全部贴顶（等同普通竖排）。
  final int split;
  final double gap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPosterSpread(split: split, gap: gap);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPosterSpread renderObject,
  ) {
    renderObject
      ..split = split
      ..gap = gap;
  }
}

class _PosterSpreadParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPosterSpread extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PosterSpreadParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PosterSpreadParentData> {
  _RenderPosterSpread({required int split, required double gap})
    : _split = split,
      _gap = gap;

  int _split;
  set split(int v) {
    if (v == _split) return;
    _split = v;
    markNeedsLayout();
  }

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PosterSpreadParentData) {
      child.parentData = _PosterSpreadParentData();
    }
  }

  List<RenderBox> get _kids {
    final List<RenderBox> kids = <RenderBox>[];
    RenderBox? child = firstChild;
    while (child != null) {
      kids.add(child);
      child = childAfter(child);
    }
    return kids;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _sumHeights((RenderBox k) => k.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _sumHeights((RenderBox k) => k.getMaxIntrinsicHeight(width));

  double _sumHeights(double Function(RenderBox kid) of) {
    final List<RenderBox> kids = _kids;
    if (kids.isEmpty) return 0;
    return kids.fold<double>(0, (double a, RenderBox k) => a + of(k)) +
        _gap * (kids.length - 1);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _kids.fold<double>(
    0,
    (double a, RenderBox k) => math.max(a, k.getMinIntrinsicWidth(height)),
  );

  @override
  double computeMaxIntrinsicWidth(double height) => _kids.fold<double>(
    0,
    (double a, RenderBox k) => math.max(a, k.getMaxIntrinsicWidth(height)),
  );

  @override
  void performLayout() {
    final List<RenderBox> kids = _kids;
    final double width = constraints.maxWidth;
    final BoxConstraints each = BoxConstraints.tightFor(width: width);
    double natural = 0;
    for (final RenderBox kid in kids) {
      kid.layout(each, parentUsesSize: true);
      natural += kid.size.height;
    }
    if (kids.isNotEmpty) natural += _gap * (kids.length - 1);
    final Size own = constraints.constrain(Size(width, natural));
    final double extra = math.max(0, own.height - natural);
    double y = 0;
    for (int i = 0; i < kids.length; i++) {
      if (i == _split) y += extra;
      (kids[i].parentData! as _PosterSpreadParentData).offset = Offset(0, y);
      y += kids[i].size.height + _gap;
    }
    size = own;
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
    this.reference,
    this.color,
    this.axisLabels,
  });

  /// 柱色（当前目标的语言色，与旁边的环同色）；null = 主题主色。墨水屏忽略。
  final Color? color;

  /// 与 [values] 对齐的横轴短标签（星期首字母）；只有 Apple（Swift Charts 口径）
  /// 画，高度够时画在细基线下面。null = 不画。
  final List<String>? axisLabels;

  /// 升序 7 天的数值（最后一个是今天）。
  final List<int> values;

  /// 参考线（与 [values] 同单位，当前目标摊到一天的量）；null = 不画。
  final double? reference;

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
    if (apple) return _buildApple(context);
    final Color? tint = eink ? null : color;
    final Color today = eink
        ? cs.onSurface
        : (tint ?? (apple ? appleColorsOf(context).accent : cs.primary));
    final Color past = eink
        ? cs.outline
        : (tint != null
              ? tint.withValues(alpha: 0.3)
              : (apple
                    ? appleColorsOf(context).accent.withValues(alpha: 0.4)
                    : cs.primaryContainer));
    final double? line = reference != null && reference! > 0 ? reference : null;
    final double peak = math.max(
      values.fold<int>(0, math.max).toDouble(),
      line ?? 0,
    );
    final Widget bars = SizedBox(
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
                  builder: (BuildContext _, double f, Widget? __) => Container(
                    height: math.max(3, height * f),
                    decoration: BoxDecoration(
                      color: i == values.length - 1 ? today : past,
                      borderRadius: const BorderRadius.all(Radius.circular(4)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return Semantics(
      container: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: line == null
          ? bars
          : FushiBarReferenceLine(
              fraction: line / peak,
              height: height,
              color: tokens.surfaces.onVariant.withValues(alpha: 0.6),
              child: bars,
            ),
    );
  }

  /// Apple（Swift Charts BarMark / Health 周图口径）：顶端圆角的柱、今天强调色
  /// （或目标语言色）、其余 systemFill 灰；0 值不画柱，只留一条 hairline 基线；
  /// 高度够时基线下是星期首字母（secondaryLabel）。柱从基线长起，时长取
  /// [fushiMotionDuration]。
  Widget _buildApple(BuildContext context) {
    final FushiAppleColors a = appleColorsOf(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final Color today = color ?? a.accent;
    final Color past = color?.withValues(alpha: 0.35) ?? a.fill;
    final double? line = reference != null && reference! > 0 ? reference : null;
    // 纵轴顶留余量（Swift Charts 自动轴取整到「好看」的刻度，最高柱不顶满）。
    final double peak =
        math.max(values.fold<int>(0, math.max).toDouble(), line ?? 0) *
        _kAppleWeekBarsHeadroom;
    final double hairline = 1 / MediaQuery.devicePixelRatioOf(context);
    final List<String>? axis = axisLabels;
    final TextStyle axisStyle =
        (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
          fontSize: (m.desktop ? 10 : 11) * m.scale,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
          height: 1.2,
          color: a.secondaryLabel,
        );
    final double axisHeight =
        MediaQuery.textScalerOf(context).scale(axisStyle.fontSize ?? 11) * 1.2 +
        2;
    // 柱区至少留 24 高才挂星期行，矮格只画柱。
    final bool showAxis =
        axis != null &&
        axis.length == values.length &&
        height >= 24 + axisHeight;
    final double barArea = showAxis ? height - axisHeight : height;
    final double gap = 4 * m.scale;
    final Widget bars = SizedBox(
      key: const ValueKey<String>('home-week-bars'),
      height: barArea,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          for (int i = 0; i < values.length; i++) ...<Widget>[
            if (i > 0) SizedBox(width: gap),
            Expanded(
              child: FushiTooltip(
                message: labels[i],
                excludeFromSemantics: true,
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(
                    begin: 0,
                    end: peak == 0 ? 0 : values[i] / peak,
                  ),
                  duration: fushiMotionDuration(context, FushiMotion.medium),
                  curve: FushiMotion.standard,
                  builder: (BuildContext _, double f, Widget? __) =>
                      LayoutBuilder(
                        builder: (BuildContext _, BoxConstraints c) {
                          final double h = values[i] == 0 ? 0 : barArea * f;
                          // 柱宽按 Swift Charts 类目轴比例：约半格宽、封顶、居中，
                          // 宽格里也不成大方块。
                          final double w = math.min(
                            c.maxWidth * _kAppleWeekBarBandShare,
                            _kAppleWeekBarMaxWidth * m.scale,
                          );
                          final double r = math.min(w / 2, 4 * m.scale);
                          return Align(
                            alignment: Alignment.bottomCenter,
                            child: SizedBox(
                              width: w,
                              height: math.max(0, h),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: i == values.length - 1 ? today : past,
                                  borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(math.min(r, h / 2)),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    final Widget plot = Stack(
      children: <Widget>[
        if (line == null)
          bars
        else
          FushiBarReferenceLine(
            fraction: line / peak,
            height: barArea,
            color: a.tertiaryLabel,
            child: bars,
          ),
        // 细基线（Swift Charts 横轴线）。
        PositionedDirectional(
          start: 0,
          end: 0,
          bottom: 0,
          child: SizedBox(
            height: hairline,
            child: ColoredBox(color: a.separator),
          ),
        ),
      ],
    );
    return Semantics(
      container: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: !showAxis
          ? plot
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                plot,
                SizedBox(
                  height: axisHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      for (int i = 0; i < axis.length; i++) ...<Widget>[
                        if (i > 0) SizedBox(width: gap),
                        Expanded(
                          child: Text(
                            axis[i],
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                            textAlign: TextAlign.center,
                            style: axisStyle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// Apple 周柱纵轴顶部余量：最高柱占柱区约 87%。
const double _kAppleWeekBarsHeadroom = 1.15;

/// Apple 周柱一根占它那一格宽的比例（Swift Charts 类目柱约半格）。
const double _kAppleWeekBarBandShare = 0.5;

/// Apple 周柱最宽多少（逻辑像素，macOS 档再乘 [FushiAppleMetrics.scale]）。
const double _kAppleWeekBarMaxWidth = 16;

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

/// 首页「今日」格的目标翻页：每个目标一页，左右滑（触屏 / 触控板 / 鼠标拖）或点
/// 下方圆点切换；切到哪页由 [onPageChanged] 记下。
///
/// **受控组件**：显示哪一页由 [page] 决定（调用方传当前页目标在列表里的位置），页序
/// 与页集合固定（不随滑动重排或增减，否则一滑就把页换了位置）。用户滑到第 i 页 →
/// [onPageChanged] 写当前页（不改主目标）→ 调用方用新的 [page] 重建，与当前页相同、
/// 不再跳；主目标在别处被改（设置里换主目标）或目标增删让当前页挪了位置 → [page] 与
/// 当前页不同 → 跳过去。
/// 页面身份因此始终是「哪条目标」，而不是一个只在首建时读一次的下标。
/// 内容区矮于此时圆点竖排在结束侧（底下一行会把页面挤得只剩一条缝）。
const double _kGoalPagerSideDotsBelow = 72;

class HomeTodayGoalPager extends StatefulWidget {
  const HomeTodayGoalPager({
    super.key,
    required this.count,
    required this.page,
    required this.pageBuilder,
    required this.onPageChanged,
    required this.dotLabel,
    required this.dotColor,
  });

  final int count;

  /// 该显示的页（夹进 0..count-1）。
  final int page;
  final IndexedWidgetBuilder pageBuilder;
  final ValueChanged<int> onPageChanged;

  /// 第 i 个圆点的读屏 / tooltip 文案（「显示 阅读时长」）。
  final String Function(int index) dotLabel;
  final Color dotColor;

  @override
  State<HomeTodayGoalPager> createState() => _HomeTodayGoalPagerState();
}

class _HomeTodayGoalPagerState extends State<HomeTodayGoalPager> {
  late int _page = _wanted;
  late final PageController _controller = PageController(initialPage: _page);

  int get _wanted => widget.page.clamp(0, math.max(0, widget.count - 1));

  @override
  void didUpdateWidget(HomeTodayGoalPager old) {
    super.didUpdateWidget(old);
    final int wanted = _wanted;
    if (wanted == _page) return;
    _page = wanted;
    // 构建期不能滚动（跳页会同步发滚动通知 → onPageChanged → 写偏好）：等这一帧
    // 布局完再跳。期间又换了目标页就跳最新的那个。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients || _page != wanted) return;
      if (_controller.page?.round() != wanted) _controller.jumpToPage(wanted);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    unawaited(
      _controller.animateToPage(
        index,
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.enter,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget pages = ScrollConfiguration(
      // 桌面上也能用鼠标拖着翻页（默认只认触屏 / 触控笔 / 触控板）。
      behavior: ScrollConfiguration.of(
        context,
      ).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
      child: PageView.builder(
        controller: _controller,
        itemCount: widget.count,
        onPageChanged: (int i) {
          setState(() => _page = i);
          widget.onPageChanged(i);
        },
        itemBuilder: widget.pageBuilder,
      ),
    );
    if (widget.count <= 1) return pages;
    final Duration swap = fushiMotionDuration(context, FushiMotion.short);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        // 矮格（手机上的 1×1）放不下底下一行圆点：圆点竖排在结束侧，页面占满高度。
        final bool side = box.maxHeight < _kGoalPagerSideDotsBelow;
        final List<Widget> dots = <Widget>[
          for (int i = 0; i < widget.count; i++)
            FushiTooltip(
              message: widget.dotLabel(i),
              child: Semantics(
                button: true,
                selected: i == _page,
                label: widget.dotLabel(i),
                excludeSemantics: true,
                child: InkResponse(
                  key: ValueKey<String>('home-today-goal-dot-$i'),
                  onTap: () => _goTo(i),
                  radius: 12,
                  child: SizedBox(
                    width: side ? 14 : 20,
                    height: side ? 12 : 16,
                    child: Center(
                      child: AnimatedContainer(
                        duration: swap,
                        curve: FushiMotion.enter,
                        width: side ? 6 : (i == _page ? 14 : 6),
                        height: side ? (i == _page ? 10 : 6) : 6,
                        // 胶囊点：短边恒为 6，StadiumBorder 即半径 3 的圆端。
                        decoration: ShapeDecoration(
                          color: widget.dotColor.withValues(
                            alpha: i == _page ? 1 : 0.35,
                          ),
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ];
        if (side) {
          return Row(
            children: <Widget>[
              Expanded(child: pages),
              // 页内容写满宽度时（一行高的「语言目标」格）别和圆点贴在一起。
              const SizedBox(width: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(mainAxisSize: MainAxisSize.min, children: dots),
              ),
            ],
          );
        }
        return Column(
          children: <Widget>[
            Expanded(child: pages),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: dots),
          ],
        );
      },
    );
  }
}
