/// Apple（Cupertino，iOS 27 / macOS 27）下载页的任务行（用户 2026-11-24 拍板
/// 方案 A，效果图 `build/browse_cupertino_design/index.html`「下载 › 任务」）。
///
/// 只是 [DownloadTaskCard] 在 `isGlassDesign` 下的外观：数据、行尾主操作、菜单
/// 动作全部来自各来源交给卡片的同一份参数，本文件不持有任何业务状态。
///
/// - 行首中性灰圆角方块 glyph（媒体类型图标；有封面换小封面），标题，4pt 进度条，
///   副行「状态 · 62% · 12.4 MB/s · 剩余 3 分 · 副标题」（阶段写在状态位）；
/// - 行尾一枚圆钮 = 卡片的主操作（暂停 / 继续 / 重试 …）；没有主操作时是展开
///   chevron；
/// - 点按展开详情（与 M3E 卡同一份 [DownloadTaskCard.details]）；长按 / 右键 /
///   菜单键 / Shift+F10 弹出行菜单（[showFushiMenu]）；
/// - 焦点：整行一个停靠点，Enter 触发主操作（没有主操作时展开详情），Space 展开 /
///   收起详情；macOS 档悬停或聚焦时行尾露出「⋯」。
///
/// 在任务浏览器里由 [DownloadTaskSegmentScope] 标明它在分组里的位置，分组底与
/// 分隔线由浏览器画（[AppleDownloadTaskSlice]）；单独使用时自己铺一块分组面。
library;

import 'dart:async' show unawaited;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show showFushiMenu;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiPopupMenuItem;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 行菜单里「展开详情」的保留 id（来源自己没给 `details` 动作时补这一项）。
const String kAppleDownloadInlineDetailsMenuId = '__apple-inline-details';

/// Apple 状态色：只用系统色，不按任务取色（进度条 / 状态字）。
Color appleDownloadToneColor(BuildContext context, DownloadTaskTone tone) {
  final FushiAppleColors apple = appleColorsOf(context);
  return switch (tone) {
    DownloadTaskTone.active => apple.accent,
    DownloadTaskTone.paused => apple.secondaryLabel,
    DownloadTaskTone.completed => apple.success,
    DownloadTaskTone.error => apple.destructive,
    DownloadTaskTone.neutral => apple.accent,
  };
}

/// 把锚点矩形（overlay 坐标）换成 [showFushiMenu] 的位置。
RelativeRect appleDownloadMenuPosition(BuildContext anchor, {Offset? at}) {
  final RenderObject? box = anchor.findRenderObject();
  final RenderObject? overlay = Navigator.of(
    anchor,
  ).overlay?.context.findRenderObject();
  if (box is! RenderBox || overlay is! RenderBox) {
    return RelativeRect.fill;
  }
  final Rect rect = at != null
      ? Rect.fromLTWH(
          overlay.globalToLocal(at).dx,
          overlay.globalToLocal(at).dy,
          0,
          0,
        )
      : Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(
            box.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        );
  return RelativeRect.fromRect(rect, Offset.zero & overlay.size);
}

/// 行首图标方块：iOS 40 / macOS 28（乘 [fushiAppleMacScale]），中性 systemFill
/// 底 + label 色字形；有封面时换 2:3 小封面。
class AppleDownloadGlyph extends StatelessWidget {
  const AppleDownloadGlyph({this.icon, this.coverUrl, super.key});

  final Widget? icon;
  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors colors = appleColorsOf(context);
    final double size = (metrics.desktop ? 28 : 40) * metrics.scale;
    final Widget tile = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.fill,
          borderRadius: BorderRadius.circular(size * 0.22),
        ),
        child: Center(
          child: IconTheme.merge(
            data: IconThemeData(color: colors.label, size: size * 0.5),
            child: icon ?? FushiIcon(FushiIcons.downloading),
          ),
        ),
      ),
    );
    if (coverUrl?.trim().isNotEmpty != true) return tile;
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: DownloadTaskCoverThumb(
          url: coverUrl,
          width: size * 2 / 3,
          fallback: tile,
        ),
      ),
    );
  }
}

/// 4pt 圆头进度条（Apple 线性进度：fill 轨 + 状态色进度）。
class AppleDownloadProgressBar extends StatelessWidget {
  const AppleDownloadProgressBar({
    required this.value,
    required this.color,
    super.key,
  });

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const double height = 4;
    return Semantics(
      value: '${(value * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: SizedBox(
          height: height,
          child: ColoredBox(
            color: appleColorsOf(context).fill,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: AnimatedFractionallySizedBox(
                duration: fushiMotionDuration(context, FushiMotion.medium),
                curve: FushiMotion.standard,
                widthFactor: value.clamp(0, 1).toDouble(),
                heightFactor: 1,
                child: ColoredBox(color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 行尾圆钮（主操作）：fill 底圆 + 强调色字形；不单独占焦点停靠点（行的 Enter
/// 就是它），指针照常可点。
class AppleDownloadRoundButton extends StatelessWidget {
  const AppleDownloadRoundButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors colors = appleColorsOf(context);
    final double size = (metrics.desktop ? 24 : 30) * metrics.scale;
    final bool enabled = onPressed != null;
    return FushiTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: FushiPressScale(
          enabled: enabled,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: Padding(
              // 命中区 ≥ 44（iOS）：圆钮本身小，四周补透明命中边。
              padding: EdgeInsets.all(metrics.desktop ? 4 : 7),
              child: SizedBox.square(
                dimension: size,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: colors.fill,
                    shape: const CircleBorder(),
                  ),
                  child: Center(
                    child: FushiIcon(
                      icon,
                      size: size * 0.5,
                      color: enabled ? colors.accent : colors.tertiaryLabel,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToggleDetailsIntent extends Intent {
  const _ToggleDetailsIntent();
}

class _OpenMenuIntent extends Intent {
  const _OpenMenuIntent();
}

class AppleDownloadTaskRow extends StatefulWidget {
  const AppleDownloadTaskRow({
    required this.taskId,
    required this.title,
    required this.status,
    required this.details,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onMenuAction,
    this.subtitle,
    this.progress,
    this.leading,
    this.tone = DownloadTaskTone.neutral,
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
  final DownloadTaskTone tone;
  final List<DownloadTaskMetric> metrics;
  final DownloadTaskQuickAction? quickAction;
  final List<DownloadTaskMenuAction> menuActions;
  final DownloadTransferMethod? method;
  final bool externalSource;
  final Widget? summary;
  final String? coverUrl;
  final bool expanded;
  final VoidCallback onToggleExpanded;

  /// 按稳定 id 派发菜单动作（卡片的 `_dispatchMenuAction`）。
  final ValueChanged<String> onMenuAction;

  @override
  State<AppleDownloadTaskRow> createState() => _AppleDownloadTaskRowState();
}

class _AppleDownloadTaskRowState extends State<AppleDownloadTaskRow> {
  bool _hovered = false;
  bool _focused = false;

  void _primary() {
    final VoidCallback? quick = widget.quickAction?.onPressed;
    if (quick != null) {
      quick();
    } else {
      widget.onToggleExpanded();
    }
  }

  List<PopupMenuEntry<String>> _menuItems(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool hasDetails = widget.menuActions.any(
      (DownloadTaskMenuAction action) => action.id == 'details',
    );
    return <PopupMenuEntry<String>>[
      if (!hasDetails)
        FushiPopupMenuItem<String>(
          key: ValueKey<String>(
            'download-task-inline-details-${widget.taskId}',
          ),
          value: kAppleDownloadInlineDetailsMenuId,
          icon: FushiIcons.info,
          label: t.download_task_details,
          selected: widget.expanded,
        ),
      for (final DownloadTaskMenuAction action in widget.menuActions)
        FushiPopupMenuItem<String>(
          key: ValueKey<String>(
            'download-task-menu-item-${widget.taskId}-${action.id}',
          ),
          value: action.id,
          icon: action.icon,
          label: action.label,
          color: action.destructive ? apple.destructive : null,
        ),
    ];
  }

  Future<void> _openMenu({Offset? at}) async {
    if (!mounted) return;
    final String? id = await showFushiMenu<String>(
      context: context,
      position: appleDownloadMenuPosition(context, at: at),
      items: _menuItems(context),
    );
    if (id == null || !mounted) return;
    if (id == kAppleDownloadInlineDetailsMenuId) {
      widget.onToggleExpanded();
      return;
    }
    widget.onMenuAction(id);
  }

  Widget _buildMeta(BuildContext context, FushiAppleMetrics metrics) {
    final FushiAppleColors apple = appleColorsOf(context);
    final TextStyle base = metrics
        .subtitleStyle(context)
        .copyWith(
          fontSize: (metrics.desktop ? 11 : 13) * metrics.scale,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );
    final Color statusColor = switch (widget.tone) {
      DownloadTaskTone.completed => apple.success,
      DownloadTaskTone.error => apple.destructive,
      _ => apple.secondaryLabel,
    };
    final double? progress = widget.progress?.clamp(0, 1).toDouble();
    const String dot = ' · ';
    final DownloadTransferMethod? method = widget.method;
    final List<InlineSpan> spans = <InlineSpan>[
      TextSpan(
        text: widget.status,
        style: TextStyle(color: statusColor),
      ),
      if (progress != null && progress < 1)
        TextSpan(text: '$dot${(progress * 100).round()}%'),
      for (final DownloadTaskMetric metric in widget.metrics)
        TextSpan(
          text: '$dot${metric.label}',
          semanticsLabel: metric.tooltip == null
              ? null
              : '${metric.tooltip} ${metric.label}',
        ),
      if (widget.subtitle?.trim().isNotEmpty ?? false)
        TextSpan(text: '$dot${widget.subtitle!.trim()}'),
      if (method != null) TextSpan(text: '$dot${method.label}'),
      // 外部来源按所有者 2026-10-09 必须标出：Apple 下是警示色文字，不用 tag。
      if (method != null && widget.externalSource)
        TextSpan(
          text: '$dot${t.download_source_external}',
          style: TextStyle(color: apple.warning),
        ),
    ];
    return Text.rich(
      TextSpan(style: base, children: spans),
      key: ValueKey<String>('apple-download-task-meta-${widget.taskId}'),
      maxLines: metrics.desktop ? 1 : 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget? _buildTrailing(BuildContext context, FushiAppleMetrics metrics) {
    final DownloadTaskQuickAction? quick = widget.quickAction;
    final Widget? primary = quick == null
        ? null
        : AppleDownloadRoundButton(
            key: quick.key,
            icon: quick.icon,
            tooltip: quick.tooltip,
            onPressed: quick.onPressed,
          );
    final Widget disclosure = AnimatedRotation(
      turns: widget.expanded ? 0.25 : 0,
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      child: const FushiAppleChevron(),
    );
    // macOS 档：悬停 / 聚焦才露「⋯」（右键菜单同长按菜单）。
    final bool showMore = metrics.desktop && (_hovered || _focused);
    final Widget more = AnimatedOpacity(
      opacity: showMore ? 1 : 0,
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      child: IgnorePointer(
        ignoring: !showMore,
        child: ExcludeFocus(
          child: Builder(
            builder: (BuildContext buttonContext) => AppleDownloadRoundButton(
              key: ValueKey<String>('download-task-menu-${widget.taskId}'),
              icon: FushiIcons.more,
              tooltip: t.common_more_actions,
              onPressed: () => unawaited(_openMenu()),
            ),
          ),
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[if (metrics.desktop) more, primary ?? disclosure],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final DownloadTaskSegmentScope? segment = DownloadTaskSegmentScope.maybeOf(
      context,
    );
    final double? progress = widget.progress?.clamp(0, 1).toDouble();
    final bool showBar =
        progress != null &&
        progress < 1 &&
        widget.tone != DownloadTaskTone.completed;
    final double k = metrics.scale;
    final TextStyle titleStyle = metrics
        .titleStyle(context)
        .copyWith(
          fontSize: (metrics.desktop ? 13 : 15) * k,
          fontWeight: FontWeight.w500,
        );
    final Widget content = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        metrics.rowHorizontal,
        (metrics.desktop ? 6 : 10) * k,
        (metrics.desktop ? 8 : 6) * k,
        (metrics.desktop ? 6 : 10) * k,
      ),
      child: Row(
        children: <Widget>[
          AppleDownloadGlyph(icon: widget.leading, coverUrl: widget.coverUrl),
          SizedBox(width: (metrics.desktop ? 10 : 12) * k),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
                if (showBar) ...<Widget>[
                  SizedBox(height: 5 * k),
                  AppleDownloadProgressBar(
                    key: ValueKey<String>(
                      'apple-download-task-progress-${widget.taskId}',
                    ),
                    value: progress,
                    color: appleDownloadToneColor(context, widget.tone),
                  ),
                  SizedBox(height: 4 * k),
                ] else
                  SizedBox(height: 2 * k),
                _buildMeta(context, metrics),
                if (widget.summary != null) ...<Widget>[
                  SizedBox(height: 6 * k),
                  widget.summary!,
                ],
              ],
            ),
          ),
          SizedBox(width: 4 * k),
          ?_buildTrailing(context, metrics),
        ],
      ),
    );
    final Widget disclosure = widget.expanded
        ? Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              metrics.rowHorizontal,
              0,
              metrics.rowHorizontal,
              12 * k,
            ),
            child: DefaultTextStyle(
              style: metrics.subtitleStyle(context),
              child: widget.details,
            ),
          )
        : const SizedBox(width: double.infinity);
    Widget row = FocusableActionDetector(
      onShowFocusHighlight: (bool value) {
        if (mounted && value != _focused) setState(() => _focused = value);
      },
      onShowHoverHighlight: (bool value) {
        if (mounted && value != _hovered) setState(() => _hovered = value);
      },
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.space): _ToggleDetailsIntent(),
        SingleActivator(LogicalKeyboardKey.contextMenu): _OpenMenuIntent(),
        SingleActivator(LogicalKeyboardKey.f10, shift: true): _OpenMenuIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _primary();
            return null;
          },
        ),
        _ToggleDetailsIntent: CallbackAction<_ToggleDetailsIntent>(
          onInvoke: (_) {
            widget.onToggleExpanded();
            return null;
          },
        ),
        _OpenMenuIntent: CallbackAction<_OpenMenuIntent>(
          onInvoke: (_) {
            unawaited(_openMenu());
            return null;
          },
        ),
      },
      child: Semantics(
        expanded: widget.expanded,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapUp: (TapUpDetails details) =>
              unawaited(_openMenu(at: details.globalPosition)),
          child: FushiPressScale(
            child: FushiAppleRow(
              key: ValueKey<String>('download-task-toggle-${widget.taskId}'),
              focusable: false,
              onTap: widget.onToggleExpanded,
              onLongPress: () => unawaited(_openMenu()),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  content,
                  FushiAnimatedSize(
                    duration: fushiMotionDuration(context, FushiMotion.medium),
                    curve: FushiMotion.standard,
                    alignment: Alignment.topCenter,
                    child: disclosure,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    row = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(
          color: _focused ? apple.accent : const Color(0x00000000),
          width: 2,
        ),
        borderRadius: BorderRadius.circular(metrics.desktop ? 6 * k : 10),
      ),
      child: row,
    );
    if (segment != null) return row;
    // 单独使用（详情对话框等）：自己铺一块 inset 分组面。
    return FushiAppleGroupSurface(child: row);
  }
}
