import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/downloads/apple/apple_download_task_row.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';

/// 任务卡的状态色调（M3E：下载中 primary、暂停中性、完成 tertiary、出错 error
/// tonal；Apple 落到强调色 / 系统绿 / 系统红 / 次级灰）。
enum DownloadTaskTone { active, paused, completed, error, neutral }

/// 任务行第二行里的一项指标（速度 / 剩余 / 大小 / 做种比……）。
class DownloadTaskMetric {
  const DownloadTaskMetric({required this.label, this.icon, this.tooltip});

  final String label;
  final IconData? icon;

  /// 指标的含义（读屏念「剩余时间 10s」，不只念一个裸数字）。
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

/// 任务行在所属分段组里的位置（M3E segmented list：组首尾大圆角、中间小圆角、
/// 行间 2px 缝；Apple inset grouped 行间无缝）。
///
/// 由任务浏览器在每一行外面挂上（组头算第 0 格），[DownloadTaskCard] 据此取
/// 外形；不在浏览器里（详情对话框、单独一张卡）时没有这一层，卡片按独立卡画。
class DownloadTaskSegmentScope extends InheritedWidget {
  const DownloadTaskSegmentScope({
    required this.index,
    required this.count,
    required super.child,
    super.key,
  });

  final int index;
  final int count;

  static DownloadTaskSegmentScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DownloadTaskSegmentScope>();

  @override
  bool updateShouldNotify(DownloadTaskSegmentScope oldWidget) =>
      index != oldWidget.index || count != oldWidget.count;
}

/// 任务行 / 组头行首的小海报（2:3）。没有封面或加载失败时退回 [fallback]。
class DownloadTaskCoverThumb extends StatelessWidget {
  const DownloadTaskCoverThumb({
    required this.url,
    required this.fallback,
    this.width = 32,
    super.key,
  });

  final String? url;
  final Widget fallback;
  final double width;

  @override
  Widget build(BuildContext context) {
    final String value = url?.trim() ?? '';
    if (value.isEmpty) return fallback;
    final double height = width * 1.5;
    return ClipRRect(
      borderRadius: FushiM3eShape.smallRadius,
      child: SizedBox(
        width: width,
        height: height,
        child: ColoredBox(
          color: FushiDesignTokens.of(context).surfaces.group,
          child: PortraitCoverImage(
            image: AppCachedHttpImage(value),
            errorBuilder: (_) => Center(child: fallback),
          ),
        ),
      ),
    );
  }
}

/// Shared compact row and explicit disclosure for every download source.
///
/// 拼贴改版的紧凑形态（2026-11）：一行 56–72 高——行首小海报（没有封面时是
/// 状态色块徽标）、标题 + 方式 / 来源标签、一行 meta（状态 · 进度 · 指标 · 副标题，
/// 单行省略）与贴底细进度条；行尾主操作（圆形 tonal）+「⋯」菜单 + 展开箭头。
/// 展开详情用 spatial 弹簧撑开高度。在任务浏览器里由 [DownloadTaskSegmentScope]
/// 给出分段外形，与组头拼成一组 M3E 分段列表。
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
    this.method,
    this.externalSource = false,
    this.summary,
    this.coverUrl,
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

  /// 这条任务实际走的传输方式（BT / 直链 / 扩展源）；null = 不是下载（如转录
  /// 任务），不画方式标签。
  final DownloadTransferMethod? method;

  /// 内容来自第三方站点：方式标签旁多一枚「外部来源」。
  final bool externalSource;

  /// 折叠时也显示的摘要（进度条下方），如转录任务的阶段轨；null = 不画。
  final Widget? summary;

  /// 作品海报（远端 URL）；给了就以小海报代替行首状态徽标。
  final String? coverUrl;

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
        widget.leading ?? FushiIcon(FushiIcons.downloading, size: 20);
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
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: container,
        // 完成 = 圆（M3E 形状变化表达「已到终点」），其余是方圆角色块。
        borderRadius: tone == DownloadTaskTone.completed
            ? const BorderRadius.all(Radius.circular(18))
            : FushiM3eShape.smallRadius,
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: onContainer, size: 20),
        child: icon,
      ),
    );
  }

  Widget _buildLeading(BuildContext context, DownloadTaskTone tone) {
    final Widget badge = _buildBadge(context, tone);
    if (widget.coverUrl?.trim().isNotEmpty != true) return badge;
    final Color toneColor = downloadTaskToneColor(context, tone);
    final Color ring = isGlassDesign(context)
        ? appleColorsOf(context).secondaryGroupedBackground
        : Theme.of(context).colorScheme.surfaceContainerLow;
    // 小海报右下角一枚状态色点：色块徽标让位给海报后，状态色仍一眼可辨。
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        DownloadTaskCoverThumb(url: widget.coverUrl, fallback: badge),
        PositionedDirectional(
          end: -3,
          bottom: -3,
          child: AnimatedContainer(
            duration: context.fushiMotion.effectsDefault.duration,
            curve: context.fushiMotion.effectsDefault.curve,
            width: 12,
            height: 12,
            decoration: ShapeDecoration(
              color: toneColor,
              shape: CircleBorder(side: BorderSide(color: ring, width: 2)),
            ),
          ),
        ),
      ],
    );
  }

  /// 第二行：状态（色调字）· 进度 · 指标（带小图标）· 副标题，单行省略。
  Widget _buildMeta(
    BuildContext context,
    DownloadTaskTone tone,
    double? progress,
  ) {
    final ThemeData theme = Theme.of(context);
    final TextStyle base = context.fushiType.labelMedium.tabular.copyWith(
      color: isGlassDesign(context)
          ? appleColorsOf(context).secondaryLabel
          : theme.colorScheme.onSurfaceVariant,
    );
    final Color toneColor = downloadTaskToneColor(context, tone);
    const String dot = '  ·  ';
    final List<InlineSpan> spans = <InlineSpan>[
      TextSpan(
        text: widget.status,
        style: base.copyWith(color: toneColor, fontWeight: FontWeight.w700),
      ),
      if (progress != null) TextSpan(text: '$dot${(progress * 100).round()}%'),
      for (final DownloadTaskMetric metric in widget.metrics) ...<InlineSpan>[
        const TextSpan(text: dot),
        if (metric.icon != null)
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 3),
              child: FushiIcon(metric.icon, size: 13, color: base.color),
            ),
          ),
        TextSpan(
          text: metric.label,
          semanticsLabel: metric.tooltip == null
              ? null
              : '${metric.tooltip} ${metric.label}',
        ),
      ],
      if (widget.subtitle?.trim().isNotEmpty ?? false)
        TextSpan(text: '$dot${widget.subtitle!.trim()}'),
    ];
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildTitle(BuildContext context) {
    final DownloadTransferMethod? method = widget.method;
    final Widget title = Text(
      widget.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.fushiType.titleSmallEmphasized,
    );
    if (method == null) return title;
    // 方式 / 来源标签紧跟标题（所有者 2026-10-09：每条下载都要明显标出外部
    // 来源）；标题先让位省略，标签不被挤掉。
    return Row(
      children: <Widget>[
        Flexible(child: title),
        const SizedBox(width: 8),
        DownloadSourceTags(method: method, external: widget.externalSource),
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

  Widget _buildTrailing(BuildContext context) {
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
    return Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: children);
  }

  /// Apple（方案 A）：同一份数据画成 inset 分组行（[AppleDownloadTaskRow]），
  /// 展开态、菜单派发与 M3E 卡共用本 State。
  Widget _buildApple(BuildContext context) => AppleDownloadTaskRow(
    taskId: widget.taskId,
    title: widget.title,
    status: widget.status,
    subtitle: widget.subtitle,
    progress: widget.progress,
    leading: widget.leading,
    tone: widget.tone ?? DownloadTaskTone.neutral,
    metrics: widget.metrics,
    quickAction: widget.quickAction,
    menuActions: widget.menuActions,
    method: widget.method,
    externalSource: widget.externalSource,
    summary: widget.summary,
    coverUrl: widget.coverUrl,
    details: widget.details,
    expanded: _expanded,
    onToggleExpanded: _toggle,
    onMenuAction: _dispatchMenuAction,
  );

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildApple(context);
    final ThemeData theme = Theme.of(context);
    final DownloadTaskTone tone = widget.tone ?? DownloadTaskTone.neutral;
    final double? progress = widget.progress?.clamp(0, 1).toDouble();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final DownloadTaskSegmentScope? segment = DownloadTaskSegmentScope.maybeOf(
      context,
    );
    final BorderRadius radius = segment == null
        ? (isGlassDesign(context)
              ? fushiGroupedItemRadius(context, 0, 1)
              : FushiM3eShape.cardRadius)
        : fushiGroupedItemRadius(context, segment.index, segment.count);
    final Widget disclosure = _expanded
        ? Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.gap / 2,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            child: DefaultTextStyle(
              style: theme.textTheme.bodySmall!,
              child: widget.details,
            ),
          )
        : const SizedBox(width: double.infinity);
    final Widget? summary = widget.summary;
    return FushiCard(
      padding: EdgeInsets.zero,
      borderRadius: radius,
      grouped: segment != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSegmentTileScope(
            borderRadius: _expanded
                ? BorderRadius.only(
                    topLeft: radius.topLeft,
                    topRight: radius.topRight,
                  )
                : radius,
            child: FushiListItem(
              key: ValueKey<String>('download-task-toggle-${widget.taskId}'),
              onTap: _toggle,
              minHeight: 56,
              padding: EdgeInsetsDirectional.fromSTEB(
                tokens.spacing.rowHorizontal - 4,
                8,
                tokens.spacing.rowHorizontal - 8,
                8,
              ),
              leading: _buildLeading(context, tone),
              title: _buildTitle(context),
              subtitleMaxLines: 1,
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _buildMeta(context, tone, progress),
                  if (progress != null && progress < 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: FushiLinearProgressIndicator(
                        value: progress,
                        color: downloadTaskToneColor(context, tone),
                        minHeight: 3,
                      ),
                    ),
                ],
              ),
              trailing: _buildTrailing(context),
            ),
          ),
          if (summary != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                0,
                tokens.spacing.card,
                tokens.spacing.gap,
              ),
              child: summary,
            ),
          // 展开详情：spatial 弹簧撑开 / 收起高度（墨水屏与减弱动态效果下瞬时，
          // 由 FushiAnimatedSize 处理零时长）。
          FushiAnimatedSize(
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: disclosure,
          ),
        ],
      ),
    );
  }
}
