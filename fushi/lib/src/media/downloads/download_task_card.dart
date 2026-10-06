import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 任务卡的状态色调（M3E：下载中 primary、暂停中性、完成 tertiary、出错 error
/// tonal；Apple 落到强调色 / 系统绿 / 系统红 / 次级灰）。
enum DownloadTaskTone { active, paused, completed, error, neutral }

/// 卡片标题下的一枚指标 chip（速度 / 剩余 / 大小 / 做种比……）。
class DownloadTaskMetric {
  const DownloadTaskMetric({required this.label, this.icon, this.tooltip});

  final String label;
  final IconData? icon;
  final String? tooltip;
}

/// 行尾的主操作（暂停 / 继续 / 重试）：圆形 tonal 图标按钮。
class DownloadTaskQuickAction {
  const DownloadTaskQuickAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Key? key;
}

/// 「⋯」菜单里的一项。[destructive] 的项用 error 色。
///
/// [id] 是这一项的稳定动作身份：菜单弹出后任务状态仍会实时刷新，[menuActions]
/// 可能整组换掉（多了「补对齐」、busy 时清空……）。菜单值只带 [id]，选中时回到
/// **当前**的 [DownloadTaskCard.menuActions] 里按 [id] 找动作——找不到（能力已
/// 消失 / 任务正忙）就什么都不做，绝不按旧下标映射到新列表里的别的动作
/// （HBK-AUDIT-036：旧「删除」被重映射成「补对齐」）。
class DownloadTaskMenuAction {
  const DownloadTaskMenuAction({
    required this.id,
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });

  final String id;
  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool destructive;
}

/// 状态色调 → 卡片色调（行首徽标的饱和色块）。
FushiCardTone downloadTaskCardTone(DownloadTaskTone tone) => switch (tone) {
  DownloadTaskTone.active => FushiCardTone.primary,
  DownloadTaskTone.paused => FushiCardTone.secondary,
  DownloadTaskTone.completed => FushiCardTone.tertiary,
  DownloadTaskTone.error => FushiCardTone.error,
  DownloadTaskTone.neutral => FushiCardTone.secondary,
};

/// 状态色调 → 强调色（进度条 / 状态字）。
Color downloadTaskToneColor(BuildContext context, DownloadTaskTone tone) {
  if (isGlassDesign(context)) {
    final FushiAppleColors apple = appleColorsOf(context);
    return switch (tone) {
      DownloadTaskTone.active => apple.accent,
      DownloadTaskTone.paused => apple.secondaryLabel,
      DownloadTaskTone.completed => apple.success,
      DownloadTaskTone.error => apple.destructive,
      DownloadTaskTone.neutral => apple.accent,
    };
  }
  final ColorScheme cs = Theme.of(context).colorScheme;
  return switch (tone) {
    DownloadTaskTone.active => cs.primary,
    DownloadTaskTone.paused => cs.outline,
    DownloadTaskTone.completed => cs.tertiary,
    DownloadTaskTone.error => cs.error,
    DownloadTaskTone.neutral => cs.primary,
  };
}

/// Shared compact summary and explicit disclosure for every download source.
///
/// M3E 形态（2026-10）：行首状态色块徽标、标题 + 状态摘要、指标 chip 行、
/// 行尾主操作（圆形 tonal）+ 「⋯」菜单 + 展开箭头；进度条下载中走波浪、
/// 暂停 / 出错是静止实线；展开详情用 spatial 弹簧撑开高度。来源只给了
/// [leading] / [status] / [details] 的旧调用点照常工作（色调缺省为中性）。
class DownloadTaskCard extends StatefulWidget {
  const DownloadTaskCard({
    required this.taskId,
    required this.title,
    required this.status,
    required this.details,
    this.subtitle,
    this.progress,
    this.leading,
    this.tone,
    this.metrics = const <DownloadTaskMetric>[],
    this.quickAction,
    this.menuActions = const <DownloadTaskMenuAction>[],
    super.key,
  });

  final String taskId;
  final String title;
  final String status;
  final String? subtitle;
  final double? progress;
  final Widget? leading;
  final Widget details;

  /// null = 来源没给状态语义：中性徽标、主色进度。
  final DownloadTaskTone? tone;
  final List<DownloadTaskMetric> metrics;
  final DownloadTaskQuickAction? quickAction;
  final List<DownloadTaskMenuAction> menuActions;

  @override
  State<DownloadTaskCard> createState() => _DownloadTaskCardState();
}

class _DownloadTaskCardState extends State<DownloadTaskCard> {
  bool _expanded = false;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_restored) {
      _expanded =
          PageStorage.maybeOf(context)?.readState(
                context,
                identifier: 'download-expanded-${widget.taskId}',
              )
              as bool? ??
          false;
      _restored = true;
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(
      context,
      _expanded,
      identifier: 'download-expanded-${widget.taskId}',
    );
  }

  Widget _buildBadge(BuildContext context, DownloadTaskTone tone) {
    final Widget icon =
        widget.leading ?? FushiIcon(FushiIcons.downloading, size: 22);
    final FushiCardColors? colors = fushiCardToneColors(
      context,
      downloadTaskCardTone(tone),
    );
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color container = colors?.container ?? cs.surfaceContainerHighest;
    final Color onContainer = colors?.onContainer ?? cs.onSurfaceVariant;
    final FushiMotionScheme motion = context.fushiMotion;
    return AnimatedContainer(
      duration: motion.effectsDefault.duration,
      curve: motion.effectsDefault.curve,
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: container,
        // 完成 = 圆（M3E 形状变化表达「已到终点」），其余是方圆角色块。
        borderRadius: BorderRadius.circular(
          tone == DownloadTaskTone.completed ? 20 : FushiM3eShape.small,
        ),
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: onContainer, size: 22),
        child: icon,
      ),
    );
  }

  Widget _buildProgress(
    BuildContext context,
    double progress,
    DownloadTaskTone tone,
  ) {
    final Color color = downloadTaskToneColor(context, tone);
    // 暂停 / 出错 / 完成是「静止」的进度：M3E 波浪停下变实线；Apple 与墨水屏
    // 本来就是实线。
    final bool flat =
        tone == DownloadTaskTone.paused || tone == DownloadTaskTone.error;
    if (flat && !isGlassDesign(context) && !isEinkTheme(context)) {
      return FushiWavyLinearProgress(
        value: progress,
        color: color,
        trackColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        waving: false,
      );
    }
    return FushiLinearProgressIndicator(value: progress, color: color);
  }

  Widget _buildMetrics(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle style = context.fushiType.labelMedium.tabular.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final DownloadTaskMetric metric in widget.metrics)
          _MetricChip(metric: metric, style: style),
      ],
    );
  }

  /// 按稳定 [DownloadTaskMenuAction.id] 在**当前**动作表里派发；动作已不可用
  /// （能力消失、任务进入 busy 时整表清空）就丢弃这次选择。
  void _dispatchMenuAction(String id) {
    if (!mounted) return;
    for (final DownloadTaskMenuAction action in widget.menuActions) {
      if (action.id == id) {
        action.onSelected();
        return;
      }
    }
  }

  Widget? _buildTrailing(BuildContext context) {
    final DownloadTaskQuickAction? quick = widget.quickAction;
    final List<Widget> children = <Widget>[
      if (quick != null)
        FushiIconButtonControl.filledTonal(
          key: quick.key,
          tooltip: quick.tooltip,
          onPressed: quick.onPressed,
          icon: FushiIcon(quick.icon),
        ),
      if (widget.menuActions.isNotEmpty)
        FushiOverflowMenu<String>(
          key: ValueKey<String>('download-task-menu-${widget.taskId}'),
          tooltip: t.common_more_actions,
          iconWidget: const FushiIcon(FushiIcons.more),
          onSelected: _dispatchMenuAction,
          items: <PopupMenuEntry<String>>[
            for (final DownloadTaskMenuAction action in widget.menuActions)
              FushiPopupMenuItem<String>(
                value: action.id,
                icon: action.icon,
                label: action.label,
                color: action.destructive
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
          ],
        ),
      Semantics(
        expanded: _expanded,
        child: AnimatedRotation(
          turns: _expanded ? 0.5 : 0,
          duration: context.fushiMotion.spatialFast.duration,
          curve: context.fushiMotion.spatialFast.curve,
          child: const FushiIcon(FushiIcons.expandMore),
        ),
      ),
    ];
    return Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: children);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DownloadTaskTone tone = widget.tone ?? DownloadTaskTone.neutral;
    final double? progress = widget.progress?.clamp(0, 1).toDouble();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiMotionScheme motion = context.fushiMotion;
    return FushiCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiListItem(
            key: ValueKey<String>('download-task-toggle-${widget.taskId}'),
            onTap: _toggle,
            leading: _buildBadge(context, tone),
            title: Text(widget.title),
            titleMaxLines: 2,
            subtitleMaxLines: 2,
            subtitle: Text(
              <String>[
                widget.status,
                if (progress != null) '${(progress * 100).round()}%',
                if (widget.subtitle?.isNotEmpty ?? false) widget.subtitle!,
              ].join(' · '),
            ),
            trailing: _buildTrailing(context),
          ),
          if (widget.metrics.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                0,
                tokens.spacing.card,
                tokens.spacing.gap,
              ),
              child: _buildMetrics(context),
            ),
          if (progress != null && progress < 1)
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                0,
                tokens.spacing.card,
                tokens.spacing.gap + 4,
              ),
              child: _buildProgress(context, progress, tone),
            ),
          // 展开详情：spatial 弹簧撑开 / 收起高度（墨水屏与减弱动态效果下瞬时）。
          AnimatedSize(
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.card,
                      0,
                      tokens.spacing.card,
                      tokens.spacing.card,
                    ),
                    child: DefaultTextStyle(
                      style: theme.textTheme.bodySmall!,
                      child: widget.details,
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.metric, required this.style});

  final DownloadTaskMetric metric;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final Widget chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: glass
            ? appleColorsOf(context).fill
            : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(FushiM3eShape.small),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (metric.icon != null) ...<Widget>[
            FushiIcon(metric.icon, size: 14, color: style.color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              metric.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
    final String? tooltip = metric.tooltip;
    return tooltip == null ? chip : FushiTooltip(message: tooltip, child: chip);
  }
}
