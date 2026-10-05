import 'package:flutter/material.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
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
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
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
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      reverseDuration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
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

/// 台词列表的空状态：图标 + 标题 + 说明 + 下一步操作按钮（启动游戏 / 选择线程
/// 等）。各元素按序错峰进场。
class GalWorkbenchEmptyState extends StatelessWidget {
  const GalWorkbenchEmptyState({
    required this.icon,
    required this.title,
    required this.body,
    this.actions = const <Widget>[],
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Widget> parts = <Widget>[
      FushiIcon(icon, size: 44, color: theme.colorScheme.outline),
      Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      if (actions.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 18),
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
