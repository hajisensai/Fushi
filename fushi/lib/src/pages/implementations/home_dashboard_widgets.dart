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

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
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
  });

  final IconData icon;
  final String message;

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
      key: const ValueKey<String>('home-empty-state'),
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

/// 每日目标环：今日学习字数 / 目标的环形进度（MD3 Expressive 波浪环 / Apple
/// 原生环，分派在 [FushiCircularProgressIndicator] 里）。未设目标时环里放一面
/// 旗子，表示「这里可以设一个」。
///
/// 进度变化（首载 / 写库后重载 / 改目标）走一段 M3E 弹簧补间从旧值长到新值，
/// 墨水屏与「减弱动态效果」下 [fushiMotionDuration] 归零即瞬间到位。
class HomeGoalRing extends StatelessWidget {
  const HomeGoalRing({
    super.key,
    required this.fraction,
    this.size = 56,
  });

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

/// 封面卡下方标题块的文字样式（[HomeContinueCoverCard.showTitle]）。
TextStyle homeCoverTitleStyle(BuildContext context) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  return tokens.type.metadata.copyWith(
    color: tokens.surfaces.onSurface,
    fontWeight: FontWeight.w500,
  );
}

/// 封面与下方标题之间的间距。
const double kHomeCoverTitleGap = 6;

/// 封面卡下方标题块的固定高度：恰好两行（按当前字号与缩放实测，不估算），一排
/// 卡的封面因此恒在同一高度、横滑行可以定高。
double homeCoverTitleBlockHeight(BuildContext context) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: 'あ\nあ', style: homeCoverTitleStyle(context)),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 2,
  )..layout();
  final double height = painter.height;
  painter.dispose();
  return kHomeCoverTitleGap + height;
}

/// 「继续」封面卡：封面底部贴进度条，右上角挂一枚进度角标（书 = 「42%」、视频 =
/// 「第 3 集」或看到的时间点）。[showTitle] 时封面下方再挂两行标题（2026-10-10
/// 用户：「首页每一项都要有标题」）；不挂时标题只进读屏标签与桌面悬停提示。封面
/// 缺失时由调用方在 [cover] 里画「图标 + 标题」兜底。悬停抬升 + 按压回弹，焦点
/// 停靠点就是卡本身。
class HomeContinueCoverCard extends StatelessWidget {
  const HomeContinueCoverCard({
    super.key,
    required this.cover,
    required this.width,
    required this.height,
    required this.title,
    required this.onTap,
    this.progress,
    this.badgeLabel,
    this.badgeIcon,
    this.showTitle = false,
  });

  final Widget cover;
  final double width;

  /// 封面高度（不含 [showTitle] 的标题块）。
  final double height;

  /// 封面下方挂两行标题（块高见 [homeCoverTitleBlockHeight]）。
  final bool showTitle;

  /// 条目显示名：读屏标签 + 悬停提示；[showTitle] 时也画在封面下方。
  final String title;
  final VoidCallback onTap;

  /// 0..1；null = 不画进度条。
  final double? progress;

  /// 右上角进度角标文案；null 且 [badgeIcon] 也为 null = 不画角标。
  final String? badgeLabel;
  final IconData? badgeIcon;

  @override
  Widget build(BuildContext context) {
    final String? label = badgeLabel;
    final IconData? icon = badgeIcon;
    final double? value = progress;
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => FushiPressScale(
        // 读屏：整卡一个按钮节点（标题 + 进度角标），点按动作直接挂在节点上
        //（子树里的 InkWell 被 excludeSemantics 收掉）。
        child: Semantics(
          container: true,
          button: true,
          label: label == null ? title : '$title · $label',
          onTap: onTap,
          excludeSemantics: true,
          child: _withTitle(
            context,
            FushiTooltip(
              message: title,
              excludeFromSemantics: true,
              child: SizedBox(
                width: width,
                height: height,
                child: ClipRRect(
                  borderRadius: FushiBorderRadius.card,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      cover,
                      if (value != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child:
                              CoverProgressStrip(value: value.clamp(0.0, 1.0)),
                        ),
                      // 角标恒完整显示：窄卡放不下时整枚等比缩小，不被卡边裁掉。
                      if (label != null || icon != null)
                        PositionedDirectional(
                          key: const ValueKey<String>('home-cover-badge'),
                          top: 6,
                          end: 6,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: width - 12),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.topEnd,
                              child: CoverBadge(icon: icon, label: label),
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: Material(
                          type: MaterialType.transparency,
                          child: InkWell(onTap: onTap),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// [showTitle] 时在封面下方挂定高两行标题块；否则原样返回封面。
  Widget _withTitle(BuildContext context, Widget coverBox) {
    if (!showTitle) return coverBox;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        coverBox,
        // 标题也是点按面（封面上的 InkWell 只盖封面）。
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            key: const ValueKey<String>('home-cover-title'),
            width: width,
            height: homeCoverTitleBlockHeight(context),
            child: Padding(
              padding: const EdgeInsets.only(top: kHomeCoverTitleGap),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: homeCoverTitleStyle(context),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 「继续」主角卡（2026-10-10 加回）：最近一条在读 / 在看 / 在玩的条目放大成整卡——
/// 竖版封面在左，右侧依次是相对时间、标题、副标题、M3E 波浪进度条
/// （[FushiLinearProgressIndicator] 在 MD3 下即 [FushiWavyLinearProgress]，Apple /
/// 墨水屏各走原生细条）与「继续阅读 / 继续观看」主按钮。
///
/// 封面高度由调用方按布局给（竖屏小、横屏 / 宽屏大），卡内再按可用宽度夹一次：
/// 封面宽不超过卡宽的 36%，极窄屏（320）上信息列仍放得下按钮。
///
/// 交互：整卡可点（鼠标 / 触屏）且带悬停抬升 + 按压回弹；**键盘焦点只落在主
/// 按钮上**（卡本身 `canRequestFocus: false`），同一动作不占两个 Tab 停靠点。
class HomeContinueHero extends StatelessWidget {
  const HomeContinueHero({
    super.key,
    required this.cover,
    required this.coverHeight,
    required this.title,
    required this.actionLabel,
    required this.actionIcon,
    required this.onOpen,
    this.eyebrow,
    this.subtitle,
    this.progress,
    this.progressLabel,
  });

  /// 封面本体（调用方按 2:3 竖槽渲染好的 PortraitCoverImage / 占位）。
  final Widget cover;

  /// 封面期望高度（2:3）；卡宽不够时等比缩小。
  final double coverHeight;

  /// 标题上方的小字（最近一次的相对时间）；null = 不画。
  final String? eyebrow;
  final String title;
  final String? subtitle;

  /// 0..1；null = 无可展示进度（单视频无总时长、游戏）不画进度条。
  final double? progress;

  /// 进度条右侧的进度文案（「42%」「第 3 集」「12:34」）；null = 不画。
  final String? progressLabel;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final BorderRadius radius = fushiCardBorderRadius(context);
    final Color fill = apple
        ? appleColorsOf(context).tertiaryFill
        : Color.alphaBlend(
            tokens.surfaces.primaryContainer.withValues(alpha: 0.38),
            tokens.surfaces.card,
          );
    return FushiHoverLift(
      scale: 1.015,
      builder: (BuildContext context, bool _) => FushiPressScale(
        child: Material(
          key: const ValueKey<String>('home-continue-hero'),
          color: eink ? Colors.transparent : fill,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: eink
                ? BorderSide(color: tokens.surfaces.outline)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: onOpen,
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.card),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  final double coverWidth = math.min(
                    coverHeight * 2 / 3,
                    c.maxWidth * 0.36,
                  );
                  return Row(
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: FushiBorderRadius.card,
                        child: SizedBox(
                          width: coverWidth,
                          height: coverWidth * 1.5,
                          child: cover,
                        ),
                      ),
                      SizedBox(width: tokens.spacing.card + 4),
                      // 宽屏信息列封顶 480：进度条与标题不被拉成一整条长线。
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: _info(context, tokens),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _info(BuildContext context, FushiDesignTokens tokens) {
    final ThemeData theme = Theme.of(context);
    final TextStyle titleStyle =
        (theme.textTheme.titleLarge ?? tokens.type.listTitle).copyWith(
      fontWeight: FontWeight.w600,
      color: tokens.surfaces.onSurface,
    );
    final double? value = progress;
    final String? label = progressLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (eyebrow case final String text) ...<Widget>[
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.metadata.copyWith(
              color: tokens.surfaces.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
        ],
        Text(
          title,
          key: const ValueKey<String>('home-continue-hero-title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
        if (subtitle case final String sub) ...<Widget>[
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.metadata,
          ),
        ],
        if (value != null || label != null) ...<Widget>[
          SizedBox(height: tokens.spacing.card),
          Row(
            children: <Widget>[
              if (value != null)
                Expanded(
                  // 进度从 0 弹簧长到当前值（M3E 进场；墨水屏 / 减弱动态效果下
                  // 时长归零即瞬间到位）。
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0)),
                    duration: fushiMotionDuration(context, FushiMotion.long),
                    curve: FushiMotion.enter,
                    builder: (BuildContext context, double v, Widget? _) =>
                        FushiLinearProgressIndicator(
                      key:
                          const ValueKey<String>('home-continue-hero-progress'),
                      value: v,
                      minHeight: 6,
                      color: tokens.surfaces.primary,
                    ),
                  ),
                )
              else
                const Spacer(),
              if (label != null) ...<Widget>[
                SizedBox(width: tokens.spacing.gap),
                Text(
                  label,
                  maxLines: 1,
                  style: tokens.type.metadata.copyWith(
                    color: tokens.surfaces.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ],
        SizedBox(height: tokens.spacing.card),
        // 极窄屏信息列放不下整颗按钮时等比缩小，不溢出、不截字。
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: FushiFilledButton.icon(
            key: const ValueKey<String>('home-continue-hero-action'),
            onPressed: onOpen,
            icon: FushiIcon(actionIcon),
            label: Text(actionLabel),
          ),
        ),
      ],
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
  });

  final Widget cover;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final double coverHeight;

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
                ClipRRect(
                  borderRadius: FushiBorderRadius.card,
                  child: SizedBox(
                    width: coverHeight * 2 / 3,
                    height: coverHeight,
                    child: cover,
                  ),
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
