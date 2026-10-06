/// 首页 dashboard 的展示件（2026-10 重设计）：「继续」主角卡、每日目标环、
/// 首载骨架块。
///
/// 只放**纯展示**的组件——取数、筛选、打开路径都留在
/// `home_dashboard_page.dart` 的 state 里（那边有一批按源码锚点钉住的守卫）。
/// 这里的组件只吃算好的值与回调，两套设计系统（MD3 Expressive / Apple）与
/// 墨水屏的差异也在这里各自收口。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';

/// 主角卡封面槽的固定高度（宽屏横排时）。
const double kHomeHeroCoverHeight = 184;

/// 主角卡横排（封面在左、信息在右）所需的最小宽度；更窄时视频封面改为通栏
/// 16:9 顶图，书 / 游戏封面缩成小竖图。
const double kHomeHeroRowMinWidth = 520;

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

/// 「继续」区首载骨架：与 [HomeContinueHero] 同轮廓（封面块 + 三行文字条）。
class HomeContinueHeroSkeleton extends StatelessWidget {
  const HomeContinueHeroSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiSkeletonShimmer(
        child: Row(
      key: const ValueKey<String>('home-continue-skeleton'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const HomeSkeletonBlock(width: 104, height: 148),
        SizedBox(width: tokens.spacing.card),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const HomeSkeletonBlock(width: 72, height: 12),
              SizedBox(height: tokens.spacing.gap),
              const FractionallySizedBox(
                widthFactor: 0.8,
                child: HomeSkeletonBlock(height: 20),
              ),
              SizedBox(height: tokens.spacing.gap),
              const FractionallySizedBox(
                widthFactor: 0.5,
                child: HomeSkeletonBlock(height: 14),
              ),
              SizedBox(height: tokens.spacing.card),
              const HomeSkeletonBlock(height: 6),
            ],
          ),
        ),
      ],
    ));
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

/// 学习卡热力图区的首载骨架：与网格同高的一块。
class HomeHeatmapSkeleton extends StatelessWidget {
  const HomeHeatmapSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const HomeSkeletonBlock(
      key: ValueKey<String>('home-heatmap-skeleton'),
      height: 112,
    );
  }
}

/// 活动时间轴首载骨架：三行「缩略图 + 两行文字条」。
class HomeActivitySkeleton extends StatelessWidget {
  const HomeActivitySkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      key: const ValueKey<String>('home-activity-skeleton'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < 3; i++) ...<Widget>[
          if (i > 0) SizedBox(height: tokens.spacing.gap),
          Row(
            children: <Widget>[
              const HomeSkeletonBlock(width: 40, height: 40),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FractionallySizedBox(
                      alignment: AlignmentDirectional.centerStart,
                      widthFactor: 0.9 - i * 0.15,
                      child: const HomeSkeletonBlock(height: 14),
                    ),
                    SizedBox(height: tokens.spacing.gap / 2),
                    const HomeSkeletonBlock(width: 96, height: 10),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
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
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      key: const ValueKey<String>('home-empty-state'),
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: Row(
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
      ),
    );
  }
}

/// 每日目标环：今日学习字数 / 目标的环形进度（MD3 Expressive 波浪环 / Apple
/// 原生环，分派在 [FushiCircularProgressIndicator] 里）。未设目标时环里放一面
/// 旗子，表示「这里可以设一个」。
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
    final double? value = fraction;
    final Color accent = tokens.surfaces.primary;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          if (value != null)
            SizedBox.square(
              dimension: size,
              child: FushiCircularProgressIndicator(
                value: value,
                strokeWidth: 5,
                color: accent,
                backgroundColor: fushiNeutralBlockColor(context),
              ),
            )
          else
            SizedBox.square(
              dimension: size,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: fushiNeutralBlockColor(context),
                  border: isEinkTheme(context)
                      ? Border.all(color: tokens.surfaces.outline)
                      : null,
                ),
              ),
            ),
          if (value != null)
            Text(
              '${(value * 100).round()}%',
              style: context.fushiType.labelSmall.copyWith(
                fontWeight: FontWeight.w600,
                color: tokens.surfaces.onSurface,
              ),
            )
          else
            FushiIcon(Icons.flag_outlined, size: 22, color: accent),
        ],
      ),
    );
  }
}

/// 「继续」主角卡：最近一条在读 / 在看 / 在玩的条目放大成整卡——大封面 +
/// 类型与进度 + 标题 + 副标题 + 「继续阅读 / 继续观看」主按钮。
///
/// 版式随卡宽自适应（[kHomeHeroRowMinWidth]）：
/// - 宽：封面在左（视频 16:9、书 / 游戏竖版，同高），信息在右；
/// - 窄 + 视频：16:9 通栏顶图，信息在下；
/// - 窄 + 书 / 游戏：小竖封面在左，信息在右。
///
/// 交互：整卡可点（鼠标 / 触屏）且带悬停抬升 + 按压回弹；**键盘焦点只落在主
/// 按钮上**（卡本身 `canRequestFocus: false`），同一动作不占两个 Tab 停靠点。
class HomeContinueHero extends StatelessWidget {
  const HomeContinueHero({
    super.key,
    required this.cover,
    required this.landscapeCover,
    this.eyebrow,
    required this.title,
    required this.actionLabel,
    required this.actionIcon,
    required this.onOpen,
    this.subtitle,
    this.progress,
  });

  /// 封面本体（调用方按槽向渲染好的 PortraitCoverImage / 占位）。
  final Widget cover;

  /// 封面是否按横版（16:9）槽摆放。
  final bool landscapeCover;

  /// 标题上方的小字（最近一次的相对时间）；null = 不画。
  final String? eyebrow;
  final String title;
  final String? subtitle;

  /// 0..1；null = 无可展示进度（单视频无总时长、游戏）不画进度条。
  final double? progress;
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
      builder: (BuildContext context, bool hovering) => FushiPressScale(
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
                builder: (BuildContext context, BoxConstraints c) =>
                    _layout(context, tokens, c.maxWidth),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _layout(
    BuildContext context,
    FushiDesignTokens tokens,
    double width,
  ) {
    final Widget info = _info(context, tokens);
    if (width >= kHomeHeroRowMinWidth) {
      const double h = kHomeHeroCoverHeight;
      final double w = landscapeCover ? h * 16 / 9 : h * 0.7;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _coverBox(context, width: w, height: h),
          SizedBox(width: tokens.spacing.card + 4),
          Expanded(child: info),
        ],
      );
    }
    if (landscapeCover) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _coverBox(context),
          ),
          SizedBox(height: tokens.spacing.card),
          info,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _coverBox(context, width: 104, height: 148),
        SizedBox(width: tokens.spacing.card),
        Expanded(child: info),
      ],
    );
  }

  Widget _coverBox(BuildContext context, {double? width, double? height}) {
    return ClipRRect(
      borderRadius: FushiBorderRadius.card,
      child: SizedBox(width: width, height: height, child: cover),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (eyebrow case final String label) ...<Widget>[
          Text(
            label,
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
        if (value != null) ...<Widget>[
          SizedBox(height: tokens.spacing.card),
          ClipRRect(
            borderRadius: tokens.radii.chipRadius,
            child: FushiLinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 6,
              color: tokens.surfaces.primary,
            ),
          ),
        ],
        SizedBox(height: tokens.spacing.card),
        FushiFilledButton.icon(
          key: const ValueKey<String>('home-continue-hero-action'),
          onPressed: onOpen,
          icon: FushiIcon(actionIcon),
          label: Text(actionLabel),
        ),
      ],
    );
  }
}
