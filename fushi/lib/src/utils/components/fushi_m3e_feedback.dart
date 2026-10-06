// M3 Expressive 反馈类小组件（用户 2026-10-05：「所有组件都是 m3e」）：
//
// - [FushiSkeleton] / [FushiSkeletonShimmer]：首载骨架块与有界闪光；
// - [FushiRefreshIndicator]：下拉刷新（M3E contained 指示器）；
// - [FushiRichTooltip]：rich tooltip（标题 + 说明的 surfaceContainer 卡）。
//
// plain tooltip 走 [FushiTooltip] + 主题（fushi_m3e_misc_themes.dart），
// 提示条 / toast / 空状态 / 加载各有既有的唯一实现，这里不重复。
// 三档降级与全仓一致：墨水屏与「减弱动态效果」经 [fushiMotionEnabled] 关动效，
// Apple 设计系统给 iOS 口径。
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// ===========================================================================
// 骨架屏
// ===========================================================================

/// 骨架块底色：MD3 surfaceContainerHighest（M3E 占位色块），Apple
/// tertiaryFill，墨水屏透明（只画描边）。
Color fushiSkeletonColor(BuildContext context) {
  if (isEinkTheme(context)) return Colors.transparent;
  if (isGlassDesign(context)) return appleColorsOf(context).tertiaryFill;
  return Theme.of(context).colorScheme.surfaceContainerHighest;
}

/// 骨架块：与最终内容同轮廓的中性色块，数据到达时整块换成真实内容。
///
/// 自身外层没有 [FushiSkeletonShimmer] 时自带一份闪光（有界，见该类）；成组
/// 的骨架（一张卡里的封面块 + 几条文字条）应在组外包一层共享闪光，让光带
/// 一次扫过整组，而不是每块各扫各的。
class FushiSkeleton extends StatelessWidget {
  const FushiSkeleton({
    this.width,
    this.height,
    this.borderRadius,
    this.circle = false,
    super.key,
  });

  /// 文字条：高 [height]（默认 12）、全圆头、宽占父级的 [widthFactor]。
  static Widget line({double widthFactor = 1, double height = 12, Key? key}) =>
      FractionallySizedBox(
        key: key,
        widthFactor: widthFactor,
        alignment: AlignmentDirectional.centerStart,
        child: FushiSkeleton(
          height: height,
          borderRadius: BorderRadius.all(Radius.circular(height / 2)),
        ),
      );

  final double? width;
  final double? height;

  /// null = M3E 小件圆角 12（Apple 10）。
  final BorderRadius? borderRadius;

  /// 圆形（头像 / 图标位）。
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final bool eink = isEinkTheme(context);
    final Widget block = SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fushiSkeletonColor(context),
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circle
              ? null
              : borderRadius ??
                    BorderRadius.all(
                      Radius.circular(isGlassDesign(context) ? 10 : 12),
                    ),
          border: eink
              ? Border.all(color: Theme.of(context).colorScheme.outline)
              : null,
        ),
      ),
    );
    if (FushiSkeletonShimmer._inScope(context)) return block;
    return FushiSkeletonShimmer(child: block);
  }
}

/// 骨架闪光：一条柔和光带从起始侧扫到末尾侧（M3E 占位动效）。
///
/// **有界**：只扫 [cycles] 轮（默认 3 轮 ≈ 4 秒）就停在静止底色上——骨架通常只活
/// 几百毫秒，常驻的无限动画会把之后每一帧都拖进重绘，也会让测试里的
/// `pumpAndSettle` 永不收敛。墨水屏 / 减弱动态效果 / 不在前台（TickerMode 关）
/// 时不扫。
class FushiSkeletonShimmer extends StatefulWidget {
  const FushiSkeletonShimmer({required this.child, this.cycles = 3, super.key});

  final Widget child;

  /// 扫几轮后停下。
  final int cycles;

  /// 一轮的时长。
  static const Duration period = Duration(milliseconds: 1400);

  static bool _inScope(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_FushiSkeletonShimmerScope>() !=
      null;

  @override
  State<FushiSkeletonShimmer> createState() => _FushiSkeletonShimmerState();
}

class _FushiSkeletonShimmerState extends State<FushiSkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: FushiSkeletonShimmer.period,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (fushiMotionEnabled(context) && widget.cycles > 0) {
      _controller.repeat(count: widget.cycles);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    final Color highlight = Colors.white.withValues(
      alpha: brightness == Brightness.dark ? 0.10 : 0.55,
    );
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    return _FushiSkeletonShimmerScope(
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (BuildContext context, Widget? child) {
          final double t = _controller.value;
          // 停下（或从未开始）时不挂 ShaderMask，静止骨架零额外合成成本。
          if (!_controller.isAnimating) return child!;
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (Rect bounds) => LinearGradient(
              begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
              end: rtl ? Alignment.centerLeft : Alignment.centerRight,
              colors: <Color>[
                highlight.withValues(alpha: 0),
                highlight,
                highlight.withValues(alpha: 0),
              ],
              stops: const <double>[0.35, 0.5, 0.65],
              transform: _SlideGradient(t * 2 - 1),
            ).createShader(bounds),
            child: child,
          );
        },
      ),
    );
  }
}

class _FushiSkeletonShimmerScope extends InheritedWidget {
  const _FushiSkeletonShimmerScope({required super.child});

  @override
  bool updateShouldNotify(_FushiSkeletonShimmerScope oldWidget) => false;
}

/// 把渐变沿主轴平移 [fraction] 个包围盒宽度（-1 → 1 扫过整块）。
class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.fraction);

  final double fraction;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final double dx = bounds.width * fraction * 1.4;
    return Matrix4.translationValues(
      textDirection == TextDirection.rtl ? -dx : dx,
      0,
      0,
    );
  }
}

// ===========================================================================
// 下拉刷新
// ===========================================================================

/// 下拉刷新的唯一实现：M3E 的 contained 指示器——primaryContainer 圆底 +
/// onPrimaryContainer 指示弧，elevation 2；Apple 是系统灰菊花色调的浅底；
/// 墨水屏前景色无阴影。行为与 [RefreshIndicator] 完全一致（参数原样透传）。
class FushiRefreshIndicator extends StatelessWidget {
  const FushiRefreshIndicator({
    required this.onRefresh,
    required this.child,
    this.displacement = 40,
    this.edgeOffset = 0,
    this.notificationPredicate = defaultScrollNotificationPredicate,
    this.triggerMode = RefreshIndicatorTriggerMode.onEdge,
    this.semanticsLabel,
    this.semanticsValue,
    super.key,
  });

  final RefreshCallback onRefresh;
  final Widget child;
  final double displacement;
  final double edgeOffset;
  final ScrollNotificationPredicate notificationPredicate;
  final RefreshIndicatorTriggerMode triggerMode;
  final String? semanticsLabel;
  final String? semanticsValue;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context);
    final Color background;
    final Color foreground;
    if (eink) {
      background = cs.surface;
      foreground = cs.onSurface;
    } else if (apple) {
      final FushiAppleColors palette = appleColorsOf(context);
      background = palette.secondaryGroupedBackground;
      foreground = palette.secondaryLabel;
    } else {
      background = cs.primaryContainer;
      foreground = cs.onPrimaryContainer;
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      displacement: displacement,
      edgeOffset: edgeOffset,
      notificationPredicate: notificationPredicate,
      triggerMode: triggerMode,
      semanticsLabel: semanticsLabel,
      semanticsValue: semanticsValue,
      color: foreground,
      backgroundColor: background,
      elevation: eink ? 0 : 2,
      strokeWidth: 3,
      child: child,
    );
  }
}

// ===========================================================================
// rich tooltip
// ===========================================================================

/// M3 rich tooltip：surfaceContainer 卡（12 圆角、level 2 投影），可选
/// [title]（titleSmall emphasized）+ 正文（bodyMedium onSurfaceVariant），最宽
/// 320。触发 / 定位 / 无障碍与 [FushiTooltip] 一致（悬停 / 长按），只是气泡换成
/// 卡片。Apple 设计系统走 [FushiTooltip] 的玻璃胶囊（标题与正文合成两行）。
///
/// 只放说明文字：tooltip 浮层不接收指针，带按钮的说明请用菜单或对话框。
class FushiRichTooltip extends StatelessWidget {
  const FushiRichTooltip({
    required this.message,
    required this.child,
    this.title,
    this.preferBelow,
    this.waitDuration,
    this.triggerMode,
    super.key,
  });

  final String? title;
  final String message;
  final Widget child;
  final bool? preferBelow;
  final Duration? waitDuration;
  final TooltipTriggerMode? triggerMode;

  @override
  Widget build(BuildContext context) {
    final String plain = title == null ? message : '$title\n$message';
    if (isGlassDesign(context)) {
      return FushiTooltip(
        message: plain,
        preferBelow: preferBelow,
        waitDuration: waitDuration,
        triggerMode: triggerMode,
        child: child,
      );
    }
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextTheme tt = theme.textTheme;
    final bool eink = isEinkTheme(context);
    final Widget card = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainer,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          border: eink ? Border.all(color: cs.outline) : null,
          boxShadow: eink
              ? null
              : <BoxShadow>[
                  BoxShadow(
                    color: cs.shadow.withValues(alpha: 0.15),
                    blurRadius: 6,
                    spreadRadius: 2,
                    offset: const Offset(0, 2),
                  ),
                  BoxShadow(
                    color: cs.shadow.withValues(alpha: 0.3),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (title != null) ...<Widget>[
                Text(
                  title!,
                  style: tt.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                message,
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      tooltip: plain,
      child: Tooltip(
        richMessage: WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: card,
        ),
        padding: EdgeInsets.zero,
        decoration: const BoxDecoration(),
        excludeFromSemantics: true,
        preferBelow: preferBelow,
        waitDuration: waitDuration,
        triggerMode: triggerMode,
        child: child,
      ),
    );
  }
}

// ===========================================================================
// 拖拽把手
// ===========================================================================

/// 拖拽重排把手：M3 drag_indicator 图标（onSurfaceVariant），桌面悬停时出现
/// 一圈 8% 状态层圆底并换成「抓手」光标。只是视觉与光标——拖拽手势仍由外层
/// 重排组件（`FushiReorderableColumn` 等）负责。Apple 用三横线（UITableView
/// 重排控件），墨水屏无状态层。
class FushiDragHandle extends StatefulWidget {
  const FushiDragHandle({this.size = 20, this.color, super.key});

  final double size;
  final Color? color;

  @override
  State<FushiDragHandle> createState() => _FushiDragHandleState();
}

class _FushiDragHandleState extends State<FushiDragHandle> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final Color color =
        widget.color ??
        (apple ? appleColorsOf(context).tertiaryLabel : cs.onSurfaceVariant);
    final double box = widget.size + 12;
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: fushiMotionDuration(context, FushiMotion.short),
        curve: FushiMotion.standard,
        width: box,
        height: box,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          shape: const CircleBorder(),
          color: _hovering && !eink
              ? color.withValues(alpha: 0.08)
              : color.withValues(alpha: 0),
        ),
        child: FushiIcon(
          apple ? FushiIcons.dragHandle : FushiIcons.dragIndicator,
          size: widget.size,
          color: color,
        ),
      ),
    );
  }
}
