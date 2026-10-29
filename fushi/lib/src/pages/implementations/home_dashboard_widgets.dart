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

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
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

/// 「继续」横卡的封面宽高比：完整显示每集截图 / 横版画面。
const double kHomeLandscapeCoverAspect = 16 / 9;

/// 「继续」封面朝向判据（用户 2026-10-14「卡片比例跟着实际用到的图走」）：图片
/// 真实宽高比 > 1 是横图，其余（含正方形、尺寸未知）按竖卡。
bool homeCoverIsLandscape(double? aspect) => aspect != null && aspect > 1;

/// 「继续」卡封面槽尺寸：竖卡按 [portraitAspect]（宽 / 高，默认 2:3；游戏卡盒
/// 见 [homeContinuePortraitAspect]），宽 = [portraitWidth]；横卡与竖卡**同高**
///（用户 2026-10-14「应该同高」：一排封面顶边、底边都齐），宽按 16:9 推出。
Size homeContinueCoverSize({
  required double portraitWidth,
  required bool landscape,
  double portraitAspect = 2 / 3,
}) {
  final double height = portraitWidth / portraitAspect;
  if (!landscape) return Size(portraitWidth, height);
  return Size(height * kHomeLandscapeCoverAspect, height);
}

/// 「继续」竖卡的封面比例（宽 / 高）：游戏是卡盒材质的 1:1.6
/// （[kShelfGameCaseAspectRatio]，与游戏库同形），书 / 视频海报 2:3。
double homeContinuePortraitAspect(ShelfCoverMaterial? material) =>
    material == ShelfCoverMaterial.gameCase ? kShelfGameCaseAspectRatio : 2 / 3;

/// 按封面图**真实宽高比**决定「继续」卡横竖（[homeCoverIsLandscape]）。
///
/// 与卡内封面渲染共用同一个 [image]（同一 ImageStream，零额外解码）；[image] 为
/// null、首帧解码前或解码失败时按竖卡，解码出横图后重建为横卡（尺寸变化由卡片
/// 自己的 [FushiMotion] 尺寸过渡接住，不硬跳）。
class HomeCoverOrientationProbe extends StatelessWidget {
  const HomeCoverOrientationProbe({
    super.key,
    required this.image,
    required this.builder,
  });

  /// 封面源；null = 没有可用封面（恒竖卡）。
  final ImageProvider? image;
  final Widget Function(BuildContext context, bool landscape) builder;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? provider = image;
    if (provider == null) return builder(context, false);
    return _HomeCoverAspectProbe(image: provider, builder: builder);
  }
}

class _HomeCoverAspectProbe extends StatefulWidget {
  const _HomeCoverAspectProbe({required this.image, required this.builder});

  final ImageProvider image;
  final Widget Function(BuildContext context, bool landscape) builder;

  @override
  State<_HomeCoverAspectProbe> createState() => _HomeCoverAspectProbeState();
}

class _HomeCoverAspectProbeState extends State<_HomeCoverAspectProbe>
    with CoverAspectProbe<_HomeCoverAspectProbe> {
  @override
  ImageProvider probedImageOf(_HomeCoverAspectProbe widget) => widget.image;

  /// 只回答横竖，一个像素都不画：不需要主色底采样。
  @override
  bool needsBackdropSeed(double aspect) => false;

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    !coverFailed && homeCoverIsLandscape(coverAspect),
  );
}

/// 封面卡下方文字块的固定高度：与库页同一个 [ShelfCardMeta]（两行标题 + 副行 +
/// 进度条，随字号与缩放算），一排卡的封面因此恒在同一高度、横滑行可以定高。
double homeCoverTitleBlockHeight(BuildContext context) =>
    ShelfCardMeta.heightFor(context);

/// 「继续」封面卡：与库页同一套条目材质（2026-10-25 库页定版）——封面经
/// [ShelfCoverFrame] 画材质（[material]：书 = 光面书皮、视频 = 光面海报、游戏 =
/// 透明卡盒；首页一行混排，逐卡传），封面上**不压角标**。[showTitle] 时封面下方
/// 挂库页同款 [ShelfCardMeta]（2026-10-10 用户：「首页每一项都要有标题」）：两行
/// 标题 + 副行（进度文案：书 =「42%」、视频 =「第 3 集」/「▶ 12:34」）+ 进度条；
/// 不挂时标题与进度文案只进读屏标签与桌面悬停提示，进度条退回贴封面底边。封面
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
    this.material,
  });

  /// 条目材质（按条目种类逐卡给）；null = 不套材质（退回无材质封面框）。
  final ShelfCoverMaterial? material;

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

  /// 进度文案（书 =「42%」、视频 =「第 N 集」/ 时间点）：[showTitle] 时进副行，
  /// 否则只进读屏标签与悬停提示（封面上不压角标）。
  final String? badgeLabel;

  /// 副行前导图标（视频看到的时间点前的 ▶）。
  final IconData? badgeIcon;

  @override
  Widget build(BuildContext context) {
    final String? label = badgeLabel;
    final double? value = progress;
    final Widget card = FushiHoverLift(
      builder: (BuildContext context, bool _) => FushiPressScale(
        // 读屏：整卡一个按钮节点（标题 + 进度文案），点按动作直接挂在节点上
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
              message: label == null || showTitle ? title : '$title · $label',
              excludeFromSemantics: true,
              // 横竖切换（封面解码出真实宽高比后）走尺寸过渡，不硬跳。
              child: AnimatedContainer(
                duration: fushiMotionDuration(context, FushiMotion.medium),
                curve: FushiMotion.standard,
                width: width,
                height: height,
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    ShelfCoverFrame(child: cover),
                    // 不挂标题块时没有副行可放进度：退回贴封面底边的进度条。
                    if (value != null && !showTitle)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: ClipRRect(
                          borderRadius: shelfCoverRadius(context),
                          child: CoverProgressStrip(
                            value: value.clamp(0.0, 1.0),
                          ),
                        ),
                      ),
                    Positioned.fill(
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          borderRadius: shelfCoverRadius(context),
                          onTap: onTap,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final ShelfCoverMaterial? m = material;
    return m == null ? card : ShelfCoverMaterialScope(material: m, child: card);
  }

  /// [showTitle] 时在封面下方挂库页同款文字块（[ShelfCardMeta]，定高）；否则原样
  /// 返回封面。
  Widget _withTitle(BuildContext context, Widget coverBox) {
    if (!showTitle) return coverBox;
    final double? value = progress;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        coverBox,
        // 文字块也是点按面（封面上的 InkWell 只盖封面）。
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            key: const ValueKey<String>('home-cover-title'),
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.standard,
            width: width,
            height: homeCoverTitleBlockHeight(context),
            child: ShelfCardMeta(
              title: title,
              subtitle: badgeLabel,
              leadingIcon: badgeIcon,
              progress: value?.clamp(0.0, 1.0),
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
    this.landscapeCover = false,
    this.material,
  });

  /// 封面本体（调用方按槽向渲染好的 PortraitCoverImage / 占位）。
  final Widget cover;

  /// 封面的条目材质（与库页同一套：书 = 光面书皮、视频 = 光面海报、游戏 = 透明
  /// 卡盒）；null = 不套材质（退回无材质封面框）。
  final ShelfCoverMaterial? material;

  /// 竖卡封面期望高度（2:3；游戏卡盒 1:1.6）；卡宽不够时等比缩小。
  final double coverHeight;

  /// 封面是横图（每集截图 / 横版画面）：封面槽改成 16:9、宽为竖槽的
  /// 同高、16:9（不超过卡宽一半），完整显示截图。
  final bool landscapeCover;

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
    // 2026-10-28：与书架 / 漫画书架 / 游戏 / 视频首页同一张满宽「继续」大卡
    // [FushiContinueHero]（模糊封面作背景海报、行尾 56 高主按钮、悬停抬升）。
    final ShelfCoverMaterial? m = material;
    final Widget framedCover = m == null
        ? cover
        : ShelfCoverMaterialScope(material: m, child: cover);
    return FushiContinueHero(
      cardKey: const ValueKey<String>('home-continue-hero'),
      progressKey: const ValueKey<String>('home-continue-hero-progress'),
      cover: framedCover,
      coverAspectRatio: landscapeCover
          ? 16 / 9
          : (m == ShelfCoverMaterial.gameCase
                ? kShelfGameCaseAspectRatio
                : 2 / 3),
      eyebrow: eyebrow ?? actionLabel,
      title: title,
      metaLines: <String>[
        if (subtitle != null && subtitle!.isNotEmpty) subtitle!,
      ],
      progress: progress,
      progressLabel: progressLabel,
      onOpen: onOpen,
      entranceIndex: null,
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
