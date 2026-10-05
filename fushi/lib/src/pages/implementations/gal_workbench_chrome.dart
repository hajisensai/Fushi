import 'package:flutter/material.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

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
