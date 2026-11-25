import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 捕获工作台（游戏 › 工作台）的布局骨架件：会话状态条里的语义状态 chip、
/// 选中台词才出现的详情侧板、带下一步操作的空状态。
///
/// 只管呈现与动效，不碰 Hook / IPC / 捕获 / 配对逻辑——页面把已经算好的文案、
/// 语义色调与回调交进来。两套设计系统（MD3 / Apple）的配色全部经共享
/// [FushiTag] 等组件落地，这里不另起颜色。

/// 宽屏两栏的断点：列表宽度至少能放下线程选择器 + 筛选 chip 一行，再给详情侧板
/// 留出 [kGalWorkbenchDetailPaneWidth]。
const double kGalWorkbenchWideBreakpoint = 1040;

/// 宽屏详情侧板的固定宽度：本句音轨里最宽的是一行 [GalTrackTile]（试听 + 选用 +
/// 排除三个按钮 + 两行元信息），360 以下会挤掉轨道说明。
const double kGalWorkbenchDetailPaneWidth = 380;

/// 会话状态条里的一枚**不可点**语义状态 chip：图标 + 本地化文案 + 设计系统语义
/// 色调（成功 / 警告 / 错误 / 中性）。悬停给出完整说明。
class GalWorkbenchStatusChip extends StatelessWidget {
  const GalWorkbenchStatusChip({
    required this.icon,
    required this.label,
    required this.tone,
    this.tooltip,
    super.key,
  });

  final IconData icon;
  final String label;
  final FushiTagTone tone;

  /// 悬停 / 长按时的完整说明；null 时不包 tooltip。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget tag = FushiTag(
      text: label,
      icon: icon,
      iconSize: 14,
      tone: tone,
      dense: true,
    );
    final String? message = tooltip;
    if (message == null || message.isEmpty) return tag;
    return FushiTooltip(message: message, child: tag);
  }
}

/// 详情侧板的出入场：宽屏下从右侧横向展开（宽度 0 → [width]），收起时让出全部
/// 宽度给台词列表；墨水屏 / 减弱动态效果下瞬间到位。
///
/// [open] 只决定侧板在不在；换选另一句时 [child] 原地更新，不重播出入场。
class GalWorkbenchDetailPane extends StatelessWidget {
  const GalWorkbenchDetailPane({
    required this.open,
    required this.child,
    this.width = kGalWorkbenchDetailPaneWidth,
    this.gap = 12,
    super.key,
  });

  final bool open;
  final Widget child;
  final double width;
  final double gap;

  @override
  Widget build(BuildContext context) {
    // M3E：侧板宽度走 effects 弹簧（临界阻尼、无过冲——同一条动画还驱动透明度，
    // spatial 弹簧的过冲会把 opacity 推出 [0,1]）；减弱动态效果下时长归零。
    final FushiMotionScheme motion = context.fushiMotion;
    return AnimatedSwitcher(
      duration: motion.effectsSlow.duration,
      reverseDuration: motion.effectsDefault.duration,
      switchInCurve: motion.effectsSlow.curve,
      switchOutCurve: motion.effectsDefault.curve,
      transitionBuilder: (Widget child, Animation<double> animation) {
        return SizeTransition(
          sizeFactor: animation,
          axis: Axis.horizontal,
          axisAlignment: -1,
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        alignment: Alignment.centerLeft,
        children: <Widget>[...previous, if (current != null) current],
      ),
      child: open
          ? SizedBox(
              key: const ValueKey<String>('game-line-detail-pane'),
              width: width + gap,
              child: Padding(
                padding: EdgeInsets.only(left: gap),
                child: child,
              ),
            )
          : const SizedBox(
              key: ValueKey<String>('game-line-detail-pane-closed'),
              height: 0,
              width: 0,
            ),
    );
  }
}

/// 窄屏底部的出入场：[child] 非 null 时自下而上展开，null 时收起并让出高度；
/// 换成另一个非 null [child] 时原地更新，不重播。
class GalWorkbenchBottomReveal extends StatelessWidget {
  const GalWorkbenchBottomReveal({required this.child, super.key});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final Widget? content = child;
    final FushiMotionScheme motion = context.fushiMotion;
    return AnimatedSwitcher(
      duration: motion.effectsSlow.duration,
      reverseDuration: motion.effectsDefault.duration,
      switchInCurve: motion.effectsSlow.curve,
      switchOutCurve: motion.effectsDefault.curve,
      transitionBuilder: (Widget child, Animation<double> animation) {
        return SizeTransition(
          sizeFactor: animation,
          axisAlignment: 1,
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      child: content == null
          ? const SizedBox(
              key: ValueKey<String>('game-bottom-reveal-closed'),
              width: double.infinity,
            )
          : KeyedSubtree(
              key: const ValueKey<String>('game-bottom-reveal-open'),
              child: content,
            ),
    );
  }
}

/// 台词列表的空状态：M3E 色块图标 + 标题 + 说明 + 下一步操作按钮（启动游戏 /
/// 选择线程等）。各元素按序错峰进场，图标色块弹簧弹入。
///
/// 与 [FushiPlaceholderMessage] 同一视觉语言（72 色块 + titleMedium emphasized），
/// 但自己可滚动：窄高（底部本句条占位后）空态不溢出。Apple 设计系统沿用 iOS
/// ContentUnavailableView 口径（无底大图标）。
class GalWorkbenchEmptyState extends StatelessWidget {
  const GalWorkbenchEmptyState({
    required this.icon,
    required this.title,
    required this.body,
    this.actions = const <Widget>[],
    this.tone = FushiCardTone.secondary,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;

  /// 图标色块的饱和色调（M3E）：一般空态 secondary，需要用户处理的 tertiary。
  final FushiCardTone tone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiTypography type = context.fushiType;
    final bool glass = isGlassDesign(context);
    final Widget badge = glass
        ? FushiIcon(
            icon,
            size: 48,
            color: appleColorsOf(context).secondaryLabel,
          )
        : _GalEmptyBadge(icon: icon, tone: tone);
    final List<Widget> parts = <Widget>[
      badge,
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          title,
          textAlign: TextAlign.center,
          style: type.titleMediumEmphasized,
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: type.bodyMedium.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      if (actions.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: actions,
          ),
        ),
    ];
    return FushiEntranceScope(
      child: Center(
        // 可滚动：窄高（底部本句条占位后）空态不溢出。
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < parts.length; i++)
                FushiStaggeredEntrance(index: i, child: parts[i]),
            ],
          ),
        ),
      ),
    );
  }
}

/// 空状态的 M3E 图标色块：72 的 cookie 形饱和 container，挂载时 spatial 弹簧
/// 从 0.6 弹到 1（带过冲）；墨水屏 / 减弱动态效果下静止（时长为零）。
class _GalEmptyBadge extends StatelessWidget {
  const _GalEmptyBadge({required this.icon, required this.tone});

  final IconData icon;
  final FushiCardTone tone;

  @override
  Widget build(BuildContext context) {
    final FushiSpringSpec spring = context.fushiMotion.spatialDefault;
    final Duration duration = spring.duration;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: duration == Duration.zero ? 1 : 0, end: 1),
      duration: duration,
      curve: spring.curve,
      builder: (BuildContext context, double t, Widget? child) =>
          Transform.scale(scale: 0.6 + 0.4 * t, child: child),
      child: FushiListLeadingIcon(
        icon,
        shape: FushiLeadingShape.cookie,
        tone: tone,
        size: 72,
        iconSize: 32,
      ),
    );
  }
}

// ── 2026-11 工作台拼贴改版：开始块 / 实时信号 / 能力小卡 / 分区标题 ─────────────

/// 宽屏「侧栏 + 主区」两栏的断点：侧栏放会话状态块、游戏内查词与会话工具，主区
/// 是台词列表（选中一句时右侧再展开 [kGalWorkbenchDetailPaneWidth] 的详情侧板，
/// 断点要保证三栏同时出现时台词列表仍有 400 以上的宽度）。
const double kGalWorkbenchSideColumnBreakpoint = 1200;

/// 侧栏宽度：开始块的两张动作卡竖排、能力小卡两列一行都放得下。
const double kGalWorkbenchSideColumnWidth = 360;

/// 「开始」块里的一张大动作卡：M3E 形状色块图标 + 动作名 + 一句说明 + 去往箭头。
///
/// [emphasized] = 主动作（实色 primary 底；Apple 强调色底），否则是色块上的浅底
/// 次动作卡。整卡可点、带焦点目标（键盘 / 手柄 Enter 触发），悬停微浮起。
class GalWorkbenchStartTile extends StatelessWidget {
  const GalWorkbenchStartTile({
    required this.icon,
    required this.title,
    required this.hint,
    required this.onTap,
    required this.focusId,
    this.emphasized = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String hint;
  final VoidCallback onTap;
  final FushiFocusId focusId;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final bool eink = isEinkTheme(context);
    final bool glass = isGlassDesign(context);
    final Color? fill;
    final Color foreground;
    final Color badgeFill;
    final Color badgeForeground;
    if (eink) {
      fill = null;
      foreground = cs.onSurface;
      badgeFill = Colors.transparent;
      badgeForeground = cs.onSurface;
    } else if (glass) {
      final FushiAppleColors apple = appleColorsOf(context);
      fill = emphasized ? apple.accent : null;
      foreground = emphasized ? Colors.white : apple.label;
      badgeFill = emphasized
          ? Colors.white.withValues(alpha: 0.22)
          : apple.accent.withValues(alpha: 0.14);
      badgeForeground = emphasized ? Colors.white : apple.accent;
    } else {
      fill = emphasized ? cs.primary : cs.surfaceContainerLowest;
      foreground = emphasized ? cs.onPrimary : cs.onSurface;
      badgeFill = emphasized ? cs.onPrimary : cs.primaryContainer;
      badgeForeground = emphasized ? cs.primary : cs.onPrimaryContainer;
    }
    final Widget badge = DecoratedBox(
      decoration: ShapeDecoration(
        color: badgeFill,
        shape: MaterialShapeBorder(
          shape: emphasized
              ? MaterialShapes.sunny
              : MaterialShapes.cookie6Sided,
          side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
        ),
      ),
      child: SizedBox.square(
        dimension: 44,
        child: Center(child: FushiIcon(icon, size: 22, color: badgeForeground)),
      ),
    );
    final FushiMotionScheme motion = context.fushiMotion;
    return FushiHoverLift(
      builder: (BuildContext context, bool hovering) => FushiCard(
        color: fill,
        onTap: onTap,
        focusId: focusId,
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
        // Apple 走全局卡片圆角 token（连续曲率由 FushiCard 的超椭圆外形负责），
        // M3E 维持 20。
        borderRadius: glass
            ? fushiCardBorderRadius(context)
            : const BorderRadius.all(Radius.circular(20)),
        child: Row(
          children: <Widget>[
            badge,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.titleMediumEmphasized.copyWith(
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodySmall.copyWith(
                      color: foreground.withValues(alpha: 0.78),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AnimatedSlide(
              offset: Offset(hovering ? 0.15 : 0, 0),
              duration: motion.effectsFast.duration,
              curve: motion.effectsFast.curve,
              child: FushiIcon(
                FushiIcons.forward,
                size: 20,
                color: foreground.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 会话状态块里的一格实时信号（文本 / 语音 / 画面 / Anki）：状态点 + 名称 + 当前值。
///
/// 就绪与否走「图标形状 + 透明度」双通道（实心对勾 / 空心圆），墨水屏与色觉障碍下
/// 只看形状也分得清；颜色取所在色块的前景色 [foreground]，不另起语义色。
class GalWorkbenchSignal extends StatelessWidget {
  const GalWorkbenchSignal({
    required this.label,
    required this.value,
    required this.ready,
    required this.foreground,
    this.tooltip,
    super.key,
  });

  final String label;
  final String value;
  final bool ready;
  final Color foreground;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final bool eink = isEinkTheme(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final Color dim = foreground.withValues(alpha: 0.6);
    final Widget body = DecoratedBox(
      decoration: BoxDecoration(
        color: eink ? null : foreground.withValues(alpha: 0.08),
        border: eink
            ? Border.all(color: Theme.of(context).colorScheme.outline)
            : null,
        borderRadius: const BorderRadius.all(Radius.circular(14)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          children: <Widget>[
            AnimatedSwitcher(
              duration: motion.effectsDefault.duration,
              switchInCurve: motion.effectsDefault.curve,
              switchOutCurve: motion.effectsFast.curve,
              child: FushiIcon(
                ready
                    ? FushiIcons.filled(FushiIcons.success)
                    : FushiIcons.radioUnchecked,
                key: ValueKey<bool>(ready),
                size: 16,
                color: ready ? foreground : dim,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.labelMedium.copyWith(color: dim),
                  ),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.labelLargeEmphasized.copyWith(
                      color: ready ? foreground : dim,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final String? message = tooltip;
    if (message == null || message.isEmpty) return body;
    return FushiTooltip(message: message, child: body);
  }
}

/// 侧栏 / 状态块里的分区标题：小图标 + 强调小字 + 可选行尾（信息钮、风险确认等）。
class GalWorkbenchSectionHeader extends StatelessWidget {
  const GalWorkbenchSectionHeader({
    required this.icon,
    required this.title,
    this.trailing = const <Widget>[],
    super.key,
  });

  final IconData icon;
  final String title;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final Color color = isGlassDesign(context)
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 36),
      child: Row(
        children: <Widget>[
          FushiIcon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.labelLargeEmphasized.copyWith(
                color: color,
              ),
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

/// 一格能力小卡的外观（游戏内查词的模式 / 状态 / 校准档案）：小标签 + 当前值。
///
/// 只管外观：可点的卡由调用方套 [GalWorkbenchCapabilityTile]（整卡可点 + 焦点），
/// 菜单触发的卡直接放进 `FushiPopupMenuButton.child`（本类声明了菜单触发器形状，
/// 按压状态层与卡片圆角对齐）。
class GalWorkbenchCapabilityFace extends StatelessWidget
    implements FushiShapedMenuTrigger {
  const GalWorkbenchCapabilityFace({
    required this.icon,
    required this.label,
    required this.value,
    this.trailingIcon,
    this.warning = false,
    this.enabled = true,
    this.filled = true,
    super.key,
  });

  final IconData icon;
  final String label;

  /// 当前值：纯文字值传 [Text]，语义状态传 [GalWorkbenchStatusChip]。
  final Widget value;

  /// 行尾提示（菜单卡 `expand_more`、可进入的卡 `chevron_right`）。
  final IconData? trailingIcon;
  final bool warning;
  final bool enabled;

  /// 自己画浅底（菜单卡）；套在 [FushiCard] 里时由卡片出底，传 false。
  final bool filled;

  static const BorderRadius radius = BorderRadius.all(Radius.circular(16));

  @override
  ShapeBorder menuTriggerShape(BuildContext context) =>
      const RoundedRectangleBorder(borderRadius: radius);

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final Color muted = glass
        ? appleColorsOf(context).secondaryLabel
        : cs.onSurfaceVariant;
    final Color accent = warning
        ? (glass ? appleColorsOf(context).warning : cs.tertiary)
        : (glass ? appleColorsOf(context).accent : cs.primary);
    final Widget content = Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      FushiIcon(icon, size: 16, color: accent),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.fushiType.labelMedium.copyWith(
                            color: muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  DefaultTextStyle.merge(
                    style: context.fushiType.labelLargeEmphasized.copyWith(
                      color: warning ? accent : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: value,
                  ),
                ],
              ),
            ),
            if (trailingIcon != null)
              FushiIcon(trailingIcon!, size: 18, color: muted),
          ],
        ),
      ),
    );
    if (!filled) return content;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: galWorkbenchTileFill(context),
        border: eink ? Border.all(color: cs.outline) : null,
        borderRadius: radius,
      ),
      child: content,
    );
  }
}

/// 能力小卡 / 工具卡的浅底：MD3 surfaceContainerHigh、Apple secondaryFill、墨水屏
/// 无底（由描边承担边界）。
Color? galWorkbenchTileFill(BuildContext context) {
  if (isEinkTheme(context)) return null;
  if (isGlassDesign(context)) return appleColorsOf(context).secondaryFill;
  return Theme.of(context).colorScheme.surfaceContainerHigh;
}

/// 整卡可点的能力小卡（校准档案、对话校准）：[FushiCard] 出底、按压形变与焦点，
/// 内容是 [GalWorkbenchCapabilityFace]。[onTap] 为 null 时卡片不可点、内容半透明。
class GalWorkbenchCapabilityTile extends StatelessWidget {
  const GalWorkbenchCapabilityTile({
    required this.face,
    required this.onTap,
    required this.focusId,
    this.tooltip,
    super.key,
  });

  final GalWorkbenchCapabilityFace face;
  final VoidCallback? onTap;
  final FushiFocusId focusId;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget card = FushiCard(
      color: galWorkbenchTileFill(context),
      onTap: onTap,
      focusId: onTap == null ? null : focusId,
      padding: EdgeInsets.zero,
      borderRadius: GalWorkbenchCapabilityFace.radius,
      child: face,
    );
    final String? message = tooltip;
    if (message == null || message.isEmpty) return card;
    return FushiTooltip(message: message, child: card);
  }
}

/// 把若干格小卡按可用宽度排成等宽网格（放不下 [minTileWidth] 时减列）。
class GalWorkbenchTileGrid extends StatelessWidget {
  const GalWorkbenchTileGrid({
    required this.children,
    this.minTileWidth = 150,
    this.maxColumns = 4,
    this.spacing = 8,
    super.key,
  });

  final List<Widget> children;
  final double minTileWidth;
  final int maxColumns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        int columns = ((box.maxWidth + spacing) / (minTileWidth + spacing))
            .floor()
            .clamp(1, maxColumns);
        if (columns > children.length) columns = children.length;
        if (columns < 1) columns = 1;
        final double width = (box.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (final Widget child in children)
              SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}
