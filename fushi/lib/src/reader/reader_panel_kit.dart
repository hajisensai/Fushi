import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/utils.dart';

/// 阅读器侧板共享组件（导航 / 有声书 / 阅读设置 / 统计四类侧板一套视觉语言）。
///
/// 约定（2026-10 阅读器界面整合）：Material 设计系统一律 **M3 Expressive**——
/// 饱和容器色块、形状对比（大容器 28 / 内卡 20 / 小件 12）、Display 级数字、
/// 波浪进度、spring 动效；Apple 设计系统保持 Apple 观感（分组底、细线进度、
/// 14 圆角卡）。两套都只从 context 主题取色，所以阅读纸色 / 歌词模式注入的主题
/// 照样生效。墨水屏与「减弱动态效果」下所有动效归零（[fushiMotionEnabled]）。
///
/// - [ReaderPanelTabs]：分段页签（M3E 连接式按钮组，选中段弹成胶囊；Apple 分段
///   控件），绑定 [TabController]。
/// - [ReaderPanelProgress]：进度条（M3E 波浪 / Apple 细线），同一组件。
/// - [ReaderQuoteCard]：引文卡（收藏 / 搜索结果 / 句子）：左侧细色条 + 正文 +
///   次要信息行 + 可选动作。
/// - [ReaderPanelEmpty]：空状态（形状底图标 + 一句话 + 可选按钮）。
/// - [ReaderPanelHeader]：侧板页头（图标 + 标题 + 副标题 + 动作）。
/// - [ReaderPanelSectionLabel]：面板内小节标题（标题 + 右侧计数）。
/// - [ReaderShapeBadge]：M3E 装饰形状（饼干 / 花瓣 / 圆）作底的图标徽标。

/// 大容器（侧板 / sheet）圆角。
const double kReaderPanelOuterRadius = 28;

/// 内卡圆角：M3E 20 / Apple 14。
double readerPanelCardRadius(BuildContext context) =>
    isGlassDesign(context) ? 14 : 20;

/// 小件（列表行、输入框、徽标）圆角：M3E 12 / Apple 10。
double readerPanelItemRadius(BuildContext context) =>
    isGlassDesign(context) ? 10 : 12;

/// 面板里「卡片」底色：比面板底高一档的表面色（Apple 为分组二级底）。
Color readerPanelCardColor(BuildContext context) {
  if (isGlassDesign(context)) {
    return appleColorsOf(context).secondaryGroupedBackground;
  }
  return Theme.of(context).colorScheme.surfaceContainerHigh;
}

/// 面板内卡：高一档表面色 + 内卡圆角（M3E 20 / Apple 14），墨水屏加描边。
class ReaderPanelCard extends StatelessWidget {
  const ReaderPanelCard({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: readerPanelCardColor(context),
        borderRadius: BorderRadius.circular(readerPanelCardRadius(context)),
        border: isEinkTheme(context)
            ? Border.all(color: Theme.of(context).colorScheme.outline)
            : null,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// 一页签：标签 + 可选图标。
@immutable
class ReaderPanelTab {
  const ReaderPanelTab({required this.label, this.icon, this.key});

  final String label;
  final IconData? icon;

  /// 测试 / 焦点定位用的稳定 key。
  final Key? key;
}

/// 侧板分段页签：撑满宽度、与 [TabController] 双向同步（点段切页、横滑切页
/// 回写选中段）。MD3 = M3 Expressive 连接式按钮组（选中段弹成全胶囊并填强调色，
/// 按下段变宽），Apple = 分段控件——都经 [FushiSegmentedButton] 分派。
class ReaderPanelTabs extends StatelessWidget {
  const ReaderPanelTabs({
    required this.controller,
    required this.tabs,
    super.key,
  });

  final TabController controller;
  final List<ReaderPanelTab> tabs;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, _) => FushiSegmentedButton<int>(
        expandedInsets: EdgeInsets.zero,
        showSelectedIcon: false,
        segments: <ButtonSegment<int>>[
          for (int i = 0; i < tabs.length; i++)
            ButtonSegment<int>(
              value: i,
              // Apple 分段控件只认纯文本段；M3E 段带图标，选中段图标与文字同色。
              icon: glass || tabs[i].icon == null
                  ? null
                  : Icon(tabs[i].icon, size: 18),
              label: Text(
                tabs[i].label,
                key: tabs[i].key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        selected: <int>{controller.index},
        onSelectionChanged: (Set<int> next) {
          if (next.isEmpty) return;
          controller.animateTo(next.first);
        },
      ),
    );
  }
}

/// 进度条：M3E 波浪（确定态，两端收平），Apple 4px 细线。[value] 0–1。
class ReaderPanelProgress extends StatelessWidget {
  const ReaderPanelProgress({
    required this.value,
    this.color,
    this.trackColor,
    this.semanticsLabel,
    super.key,
  });

  final double value;
  final Color? color;
  final Color? trackColor;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final double v = value.clamp(0.0, 1.0);
    if (isGlassDesign(context) || isEinkTheme(context)) {
      final FushiAppleColors? apple = isGlassDesign(context)
          ? appleColorsOf(context)
          : null;
      final ColorScheme cs = Theme.of(context).colorScheme;
      final Color fill = color ?? apple?.accent ?? cs.onSurface;
      final Color track = trackColor ?? apple?.fill ?? cs.outlineVariant;
      return Semantics(
        label: semanticsLabel,
        value: '${(v * 100).round()}%',
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: v),
          duration: fushiMotionDuration(context, FushiMotion.long),
          curve: FushiMotion.enter,
          builder: (BuildContext context, double t, Widget? _) => ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: ColoredBox(
                color: track,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: t,
                    heightFactor: 1,
                    child: ColoredBox(color: fill),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color fill = color ?? cs.primary;
    final Color track = trackColor ?? cs.secondaryContainer;
    final TextDirection dir = Directionality.of(context);
    // 静止波浪（不流动相位）：阅读位置是静态读数，流动的波纹是「正在进行」的
    // 语义，而且会让面板永远处于动画中（pumpAndSettle 永不落定、白耗电）。
    // 只在数值变化时用 spring 曲线补间一次。
    return Semantics(
      label: semanticsLabel,
      value: '${(v * 100).round()}%',
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: v),
        duration: fushiMotionDuration(context, FushiMotion.long * 2),
        curve: FushiMotion.release,
        builder: (BuildContext context, double t, Widget? _) => CustomPaint(
          size: const Size(double.infinity, kReaderWavyProgressHeight),
          painter: ReaderStaticWavyPainter(
            value: t.clamp(0.0, 1.0),
            color: fill,
            trackColor: track,
            rtl: dir == TextDirection.rtl,
          ),
        ),
      ),
    );
  }
}

/// 静止波浪进度条的布局高度（线宽 5 + 2 × 振幅 3.5）。
const double kReaderWavyProgressHeight = 12;

/// M3E 波浪进度（确定态、静止相位）：已完成段是正弦波，两端振幅收平；与轨道
/// 之间留 4 的缝，轨道尾端一个停止点。
class ReaderStaticWavyPainter extends CustomPainter {
  ReaderStaticWavyPainter({
    required this.value,
    required this.color,
    required this.trackColor,
    this.rtl = false,
    this.strokeWidth = 5,
    this.amplitude = 3.5,
    this.wavelength = 30,
    this.gap = 4,
  });

  final double value;
  final Color color;
  final Color trackColor;
  final bool rtl;
  final double strokeWidth;
  final double amplitude;
  final double wavelength;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final double half = strokeWidth / 2;
    final double cy = size.height / 2;
    final double left = half;
    final double right = size.width - half;
    final double usable = right - left;
    if (usable <= 0) return;
    double xOf(double px) => rtl ? size.width - px : px;
    Paint stroke(Color c) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = c;
    final double head = (value / 0.08).clamp(0.0, 1.0);
    final double tail = ((1 - value) / 0.04).clamp(0.0, 1.0);
    final double amp =
        math.min(amplitude, math.max(0.0, (size.height - strokeWidth) / 2)) *
        Curves.easeInOut.transform(math.min(head, tail));
    final double end = left + usable * value;
    if (value > 0) {
      final Path wave = Path()..moveTo(xOf(left), cy);
      for (double x = left; x <= end; x += 1) {
        final double y =
            cy + amp * math.sin((x - left) / wavelength * 2 * math.pi);
        wave.lineTo(xOf(x), y);
      }
      canvas.drawPath(wave, stroke(color));
    }
    final double trackStart = value > 0 ? end + gap + strokeWidth : left;
    if (trackStart < right) {
      canvas.drawLine(
        Offset(xOf(trackStart), cy),
        Offset(xOf(right), cy),
        stroke(trackColor),
      );
      canvas.drawCircle(
        Offset(xOf(right), cy),
        half * 0.8,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(ReaderStaticWavyPainter old) =>
      old.value != value ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.rtl != rtl;
}

/// M3E 装饰形状。
enum ReaderBadgeShape {
  /// 圆。
  circle,

  /// 4 瓣饼干（M3E 形状库 Cookie 4）。
  cookie4,

  /// 9 瓣饼干（M3E 形状库 Cookie 9，边缘细碎起伏）。
  cookie9,

  /// 花瓣（M3E 形状库 Flower，深起伏 8 瓣）。
  flower,
}

/// 极径起伏的闭合形状（饼干 / 花瓣）；[lobes] 为 0 时退化成圆。
class ReaderPolarShapeBorder extends ShapeBorder {
  const ReaderPolarShapeBorder({this.lobes = 4, this.depth = 0.08});

  factory ReaderPolarShapeBorder.of(ReaderBadgeShape shape) => switch (shape) {
    ReaderBadgeShape.circle => const ReaderPolarShapeBorder(lobes: 0),
    ReaderBadgeShape.cookie4 => const ReaderPolarShapeBorder(
      lobes: 4,
      depth: 0.09,
    ),
    ReaderBadgeShape.cookie9 => const ReaderPolarShapeBorder(
      lobes: 9,
      depth: 0.05,
    ),
    ReaderBadgeShape.flower => const ReaderPolarShapeBorder(
      lobes: 8,
      depth: 0.13,
    ),
  };

  final int lobes;
  final double depth;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    if (lobes == 0) return Path()..addOval(rect);
    const int samples = 144;
    final Offset c = rect.center;
    final double rx = rect.width / 2;
    final double ry = rect.height / 2;
    final double norm = 1 + depth;
    final Path path = Path();
    for (int i = 0; i <= samples; i++) {
      final double theta = i / samples * 2 * math.pi - math.pi / 2;
      final double r = (1 + depth * math.cos(lobes * theta)) / norm;
      final Offset p = Offset(
        c.dx + rx * r * math.cos(theta),
        c.dy + ry * r * math.sin(theta),
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// 形状底的图标徽标：MD3（M3E）用饼干 / 花瓣装饰形状，Apple 用圆角方块
/// （SF Symbols 风格的 tinted 底）。[spin] 为 true 时进场带一点旋转回弹。
class ReaderShapeBadge extends StatelessWidget {
  const ReaderShapeBadge({
    required this.icon,
    this.size = 36,
    this.shape = ReaderBadgeShape.cookie4,
    this.color,
    this.iconColor,
    this.iconSize,
    super.key,
  });

  final IconData icon;
  final double size;
  final ReaderBadgeShape shape;
  final Color? color;
  final Color? iconColor;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color bg =
        color ?? (glass ? appleColorsOf(context).accent : cs.primary);
    final Color fg =
        iconColor ?? (glass ? appleColorsOf(context).onAccent : cs.onPrimary);
    final ShapeBorder border = glass
        ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(size / 4))
        : ReaderPolarShapeBorder.of(shape);
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(color: bg, shape: border),
        child: Center(
          child: Icon(icon, size: iconSize ?? size * 0.5, color: fg),
        ),
      ),
    );
  }
}

/// 侧板页头：图标 + 标题（M3E Title Large 加粗 / Apple Headline）+ 副标题 +
/// 右侧动作。外壳（reader_desktop_chrome.dart 的 ReaderSideSheet）是页头的唯一
/// 使用者；这里只给统一的视觉件，避免各侧板各写一份。
class ReaderPanelHeader extends StatelessWidget {
  const ReaderPanelHeader({
    required this.title,
    this.subtitle,
    this.icon,
    this.actions = const <Widget>[],
    super.key,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors? apple = glass ? appleColorsOf(context) : null;
    final String? sub = subtitle?.trim();
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            ReaderShapeBadge(
              icon: icon!,
              size: 40,
              shape: ReaderBadgeShape.cookie9,
              color: glass ? apple!.fill : theme.colorScheme.primaryContainer,
              iconColor: glass
                  ? apple!.accent
                  : theme.colorScheme.onPrimaryContainer,
              iconSize: 22,
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: glass
                      ? theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: apple!.label,
                        )
                      : theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                ),
                if (sub != null && sub.isNotEmpty)
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: glass
                          ? apple!.secondaryLabel
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// 面板内小节标题：左标题、右计数 / 补充（如「13 章」「3 条结果」）。
class ReaderPanelSectionLabel extends StatelessWidget {
  const ReaderPanelSectionLabel(this.title, {this.trailing, super.key});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final Color strong = glass
        ? appleColorsOf(context).secondaryLabel
        : theme.colorScheme.primary;
    final Color weak = glass
        ? appleColorsOf(context).tertiaryLabel
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 4, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  (glass
                          ? theme.textTheme.labelMedium
                          : theme.textTheme.labelLarge)
                      ?.copyWith(color: strong, fontWeight: FontWeight.w600),
            ),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: theme.textTheme.labelMedium?.copyWith(
                color: weak,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

/// 引文卡：左侧细色条（[accent]）+ 可选上标（章名）+ 正文（[quote]，可带
/// 命中高亮）+ 次要信息行（[meta]）+ 右下动作（[actions]）。整卡可点（[onTap]），
/// 带按压回弹；焦点可遍历（在 FushiFocusRoot 下登记成可激活目标）。
class ReaderQuoteCard extends StatelessWidget {
  const ReaderQuoteCard({
    required this.quote,
    this.accent,
    this.overline,
    this.meta,
    this.actions = const <Widget>[],
    this.onTap,
    this.focusIdPrefix = 'reader-quote-card',
    super.key,
  });

  /// 正文：纯文本用 [Text]，命中高亮用 [Text.rich]（[readerHighlightSpans]）。
  final Widget quote;
  final Color? accent;
  final String? overline;
  final String? meta;
  final List<Widget> actions;
  final VoidCallback? onTap;
  final String focusIdPrefix;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors? apple = glass ? appleColorsOf(context) : null;
    final double radius = readerPanelCardRadius(context);
    final Color rail = accent ?? fushiAccentForeground(context);
    final Color secondary = glass
        ? apple!.secondaryLabel
        : theme.colorScheme.onSurfaceVariant;
    final double bottomInset = actions.isEmpty ? 14 : 4;
    // 左侧细色条画在 CustomPaint 里（随卡高伸缩），不用 IntrinsicHeight：
    // 动作按钮 / Tooltip 一类子树不一定支持固有尺寸查询。
    final Widget content = CustomPaint(
      key: const ValueKey<String>('reader_quote_card_rail'),
      painter: _QuoteRailPainter(
        color: rail,
        start: 14,
        top: 14,
        bottom: bottomInset,
        textDirection: Directionality.of(context),
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          30,
          14,
          actions.isEmpty ? 16 : 6,
          bottomInset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (overline != null && overline!.isNotEmpty) ...<Widget>[
              Text(
                overline!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: glass ? apple!.accent : theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
            ],
            DefaultTextStyle.merge(
              style: theme.textTheme.bodyLarge?.copyWith(
                height: 1.55,
                color: glass ? apple!.label : theme.colorScheme.onSurface,
              ),
              child: quote,
            ),
            if ((meta != null && meta!.isNotEmpty) || actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        meta ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: secondary,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                    ...actions,
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    final bool focusRoot = FushiFocusRoot.maybeControllerOf(context) != null;
    final BorderRadius br = BorderRadius.circular(radius);
    Widget card = Material(
      color: readerPanelCardColor(context),
      borderRadius: br,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        // FushiFocusRoot 下由登记的焦点目标做唯一停靠点，否则 InkWell 自己可聚焦。
        canRequestFocus: !focusRoot,
        splashFactory: glass ? NoSplash.splashFactory : null,
        highlightColor: glass ? apple!.fill : null,
        child: content,
      ),
    );
    if (isEinkTheme(context)) {
      card = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: br,
          border: Border.all(color: theme.colorScheme.outline),
        ),
        child: card,
      );
    }
    card = FushiPressScale(enabled: onTap != null, child: card);
    if (onTap == null || !focusRoot) return card;
    return FushiActivatableFocusTarget(
      focusIdPrefix: focusIdPrefix,
      onTap: onTap!,
      child: card,
    );
  }
}

class _QuoteRailPainter extends CustomPainter {
  _QuoteRailPainter({
    required this.color,
    required this.start,
    required this.top,
    required this.bottom,
    required this.textDirection,
  });

  final Color color;
  final double start;
  final double top;
  final double bottom;
  final TextDirection textDirection;

  static const double width = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final double h = size.height - top - bottom;
    if (h <= 0) return;
    final double left = textDirection == TextDirection.rtl
        ? size.width - start - width
        : start;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, width, h),
        const Radius.circular(width / 2),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_QuoteRailPainter old) =>
      old.color != color ||
      old.start != start ||
      old.top != top ||
      old.bottom != bottom ||
      old.textDirection != textDirection;
}

/// 把 [text] 里 [start, end) 的命中段做成高亮 span（M3E：tertiaryContainer 底
/// + 加粗；Apple：强调色 22% 底 + 加粗）。越界时整段不高亮。
TextSpan readerHighlightSpans(
  BuildContext context, {
  required String text,
  required int start,
  required int end,
}) {
  final int s = start.clamp(0, text.length);
  final int e = end.clamp(s, text.length);
  if (s == e) return TextSpan(text: text);
  final bool glass = isGlassDesign(context);
  final ColorScheme cs = Theme.of(context).colorScheme;
  final TextStyle hit = glass
      ? TextStyle(
          backgroundColor: appleColorsOf(
            context,
          ).accent.withValues(alpha: 0.22),
          fontWeight: FontWeight.w700,
        )
      : TextStyle(
          backgroundColor: cs.tertiaryContainer,
          color: cs.onTertiaryContainer,
          fontWeight: FontWeight.w700,
        );
  return TextSpan(
    children: <InlineSpan>[
      TextSpan(text: text.substring(0, s)),
      TextSpan(text: text.substring(s, e), style: hit),
      TextSpan(text: text.substring(e)),
    ],
  );
}

/// 空状态：形状底大图标 + 一句话 + 可选按钮。进场带一点缩放回弹。
class ReaderPanelEmpty extends StatelessWidget {
  const ReaderPanelEmpty({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors? apple = glass ? appleColorsOf(context) : null;
    final Widget badge = glass
        ? Icon(icon, size: 48, color: apple!.tertiaryLabel)
        : ReaderShapeBadge(
            icon: icon,
            size: 96,
            shape: ReaderBadgeShape.flower,
            color: theme.colorScheme.tertiaryContainer,
            iconColor: theme.colorScheme.onTertiaryContainer,
            iconSize: 40,
          );
    return Padding(
      key: const ValueKey<String>('reader_nav_empty'),
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.6, end: 1),
            duration: fushiMotionDuration(context, FushiMotion.long),
            curve: FushiMotion.release,
            builder: (BuildContext context, double s, Widget? child) =>
                Transform.scale(scale: s, child: child),
            child: badge,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: glass
                  ? apple!.secondaryLabel
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
