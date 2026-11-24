/// Apple（Cupertino，iOS 27 / macOS 27）下载页「任务」的列表件（方案 A）：
/// 汇总行、分组切片（inset grouped 背景 + 分隔线 + 左右滑动作）、组标题、空态 /
/// 骨架、作品聚焦 token、侧窗格的状态行。
///
/// 全部是吃回调的纯视图：筛选 / 分组 / 批量 / 各行动作都在
/// `DownloadTaskBrowser` 的 State 里，只有一份。颜色只用 [appleColorsOf] 的系统色。
library;

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show settingsSectionTitleActionStyle;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi/src/utils/components/apple/apple_radii.dart';

/// 汇总行要的计数（与 M3E 汇总 hero 同一口径，见 `summarizeDownloadTasks`）。
class AppleDownloadSummaryData {
  const AppleDownloadSummaryData({
    required this.downBps,
    required this.upBps,
    required this.active,
    required this.queued,
    required this.completed,
  });

  final int downBps;
  final int upBps;
  final int active;
  final int queued;
  final int completed;
}

/// 分组里第 [index] / [count] 行的圆角（组首上圆角、组尾下圆角）。
BorderRadius appleDownloadSliceRadius(
  BuildContext context,
  int index,
  int count,
) {
  final Radius r = Radius.circular(FushiAppleMetrics.of(context).groupRadius);
  return BorderRadius.vertical(
    top: index <= 0 ? r : Radius.zero,
    bottom: index >= count - 1 ? r : Radius.zero,
  );
}

/// 组内文字动作（「全部暂停」「本机 ›」）：强调色 / 次级色文字，按压缩放，可聚焦。
class AppleDownloadTextAction extends StatelessWidget {
  const AppleDownloadTextAction({
    required this.label,
    required this.onTap,
    this.icon,
    this.trailingChevron = false,
    this.secondary = false,
    this.tooltip,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool trailingChevron;

  /// 次级色（执行设备 token）；false = 强调色动作。
  final bool secondary;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final bool enabled = onTap != null;
    final Color color = !enabled
        ? apple.tertiaryLabel
        : secondary
        ? apple.secondaryLabel
        : apple.accent;
    final TextStyle style =
        settingsSectionTitleActionStyle(context, enabled: enabled).copyWith(
          color: color,
          fontSize: (metrics.desktop ? 12 : 15) * metrics.scale,
        );
    Widget child = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 3,
      children: <Widget>[
        if (icon != null)
          FushiIcon(icon, size: (style.fontSize ?? 15) - 1, color: color),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        if (trailingChevron)
          FushiIcon(
            FushiIcons.chevronRight,
            size: (style.fontSize ?? 15) - 1,
            color: color,
          ),
      ],
    );
    child = FushiAppleRow(
      onTap: onTap,
      enabled: enabled,
      stateBackground: false,
      borderRadius: FushiAppleRadii.of(context).selectionRadius,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: metrics.desktop ? 24 : 32),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Align(widthFactor: 1, child: child),
        ),
      ),
    );
    child = FushiPressScale(enabled: enabled, child: child);
    if (tooltip != null) child = FushiTooltip(message: tooltip, child: child);
    return child;
  }
}

/// 汇总行（列表第一组的第一行 / macOS 侧窗格第一组）：总速度大号等宽数字 + 计数，
/// 行尾执行设备 token（点去下载设置）+「全部暂停 / 全部继续」文字钮。
class AppleDownloadSummaryRow extends StatelessWidget {
  const AppleDownloadSummaryRow({
    required this.data,
    this.executionDeviceLabel,
    this.onOpenExecutionSettings,
    this.onPauseAll,
    this.onResumeAll,
    super.key,
  });

  final AppleDownloadSummaryData data;
  final String? executionDeviceLabel;
  final VoidCallback? onOpenExecutionSettings;
  final VoidCallback? onPauseAll;
  final VoidCallback? onResumeAll;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final double k = metrics.scale;
    final String speed = FushiByteFormat.speed(data.downBps.toDouble());
    final int split = speed.lastIndexOf(' ');
    final String number = split < 0 ? speed : speed.substring(0, split);
    final String unit = split < 0 ? '' : speed.substring(split + 1);
    const List<FontFeature> tabular = <FontFeature>[
      FontFeature.tabularFigures(),
    ];
    final TextStyle big = metrics
        .titleStyle(context)
        .copyWith(
          fontSize: (metrics.desktop ? 22 : 28) * k,
          fontWeight: FontWeight.w700,
          height: 1.1,
          fontFeatures: tabular,
        );
    final TextStyle unitStyle = metrics
        .subtitleStyle(context)
        .copyWith(
          fontSize: (metrics.desktop ? 12 : 15) * k,
          fontWeight: FontWeight.w600,
          fontFeatures: tabular,
        );
    final TextStyle meta = metrics
        .subtitleStyle(context)
        .copyWith(
          fontSize: (metrics.desktop ? 11 : 13) * k,
          fontFeatures: tabular,
        );
    final String counts = <String>[
      t.download_summary_active(n: data.active),
      t.download_summary_queued(n: data.queued),
      t.download_summary_completed(n: data.completed),
      if (data.upBps > 0) '↑ ${FushiByteFormat.speed(data.upBps.toDouble())}',
    ].join(' · ');
    final String? device = executionDeviceLabel;
    // 有可暂停的就给「全部暂停」，否则有可继续的给「全部继续」。
    final bool pause = onPauseAll != null || onResumeAll == null;
    return Padding(
      key: const ValueKey<String>('download-summary-apple'),
      padding: EdgeInsetsDirectional.fromSTEB(
        metrics.rowHorizontal,
        12 * k,
        (metrics.desktop ? 8 : 12) * k,
        12 * k,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  label: t.download_summary_speed_title,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text.rich(
                      key: const ValueKey<String>('download-summary-down'),
                      TextSpan(
                        children: <InlineSpan>[
                          TextSpan(text: number, style: big),
                          if (unit.isNotEmpty)
                            TextSpan(text: ' $unit', style: unitStyle),
                        ],
                      ),
                      maxLines: 1,
                    ),
                  ),
                ),
                SizedBox(height: 4 * k),
                Text(
                  counts,
                  key: const ValueKey<String>('download-summary-counts'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: meta,
                ),
              ],
            ),
          ),
          SizedBox(width: 8 * k),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            spacing: 2 * k,
            children: <Widget>[
              AppleDownloadTextAction(
                key: const ValueKey<String>('download-summary-execution'),
                label: device != null
                    ? t.download_target_remote(device: device)
                    : t.download_target_local,
                tooltip: t.download_target_label,
                secondary: true,
                trailingChevron: onOpenExecutionSettings != null,
                onTap: onOpenExecutionSettings,
              ),
              AppleDownloadTextAction(
                key: ValueKey<String>(
                  pause
                      ? 'download-summary-pause-all'
                      : 'download-summary-resume-all',
                ),
                icon: pause ? FushiIcons.pause : FushiIcons.play,
                label: pause ? t.download_pause_all : t.download_resume_all,
                onTap: pause ? onPauseAll : onResumeAll,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 一条滑动动作（右滑暂停 / 继续、左滑删除）。
class AppleDownloadSwipeAction {
  const AppleDownloadSwipeAction({
    required this.icon,
    required this.label,
    required this.onTriggered,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTriggered;
  final bool destructive;
}

/// 分组切片：一行任务在 inset 分组里的那一段背景（组首尾圆角、组内分隔线），
/// 外加 iOS 式左右滑动作——[leading]（从起始边拉出，暂停 / 继续）与
/// [trailing]（从结束边拉出，删除）。拉过 30% 宽或快速甩动即触发，松手回弹。
/// 读屏经 [CustomSemanticsAction] 拿到同样两个动作；键盘用户走行菜单。
class AppleDownloadTaskSlice extends StatefulWidget {
  const AppleDownloadTaskSlice({
    required this.index,
    required this.count,
    required this.child,
    this.leading,
    this.trailing,
    this.separatorIndent,
    super.key,
  });

  final int index;
  final int count;
  final Widget child;
  final AppleDownloadSwipeAction? leading;
  final AppleDownloadSwipeAction? trailing;

  /// 分隔线起始缩进；null = 行内边距 + 行首方块 + 间距（与标题左对齐）。
  final double? separatorIndent;

  @override
  State<AppleDownloadTaskSlice> createState() => _AppleDownloadTaskSliceState();
}

class _AppleDownloadTaskSliceState extends State<AppleDownloadTaskSlice>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settle = AnimationController(vsync: this)
    ..addListener(_onSettleTick);
  double _dx = 0;
  double _settleFrom = 0;
  double _width = 1;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _onSettleTick() {
    setState(
      () => _dx =
          _settleFrom * (1 - FushiMotion.release.transform(_settle.value)),
    );
  }

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  /// 正值 = 朝结束边方向拉（露出起始边的 [leading]）。
  double _logical(double dx) => _rtl ? -dx : dx;

  void _onUpdate(DragUpdateDetails details) {
    if (_settle.isAnimating) _settle.stop();
    double next = _dx + details.delta.dx;
    final double logical = _logical(next);
    if (logical > 0 && widget.leading == null) next = 0;
    if (logical < 0 && widget.trailing == null) next = 0;
    setState(() => _dx = next.clamp(-_width * 0.8, _width * 0.8));
  }

  void _onEnd(DragEndDetails details) {
    final double logical = _logical(_dx);
    final double velocity = _logical(details.primaryVelocity ?? 0);
    final bool far = logical.abs() >= _width * 0.3;
    final bool fling = velocity.abs() > 800 && velocity.sign == logical.sign;
    if (far || fling) {
      final AppleDownloadSwipeAction? action = logical > 0
          ? widget.leading
          : widget.trailing;
      action?.onTriggered();
    }
    _settleFrom = _dx;
    _settle
      ..duration = fushiMotionDuration(context, FushiMotion.short)
      ..forward(from: 0);
  }

  Widget _actionPane(
    AppleDownloadSwipeAction action,
    Color background,
    AlignmentGeometry alignment,
  ) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final Color foreground = appleColorsOf(context).onAccent;
    return ColoredBox(
      color: background,
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: metrics.rowHorizontal + 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIcon(action.icon, size: 20, color: foreground),
              const SizedBox(height: 2),
              Text(
                action.label,
                maxLines: 1,
                style: metrics
                    .footnoteStyle(context)
                    .copyWith(color: foreground, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final BorderRadius radius = appleDownloadSliceRadius(
      context,
      widget.index,
      widget.count,
    );
    final bool last = widget.index >= widget.count - 1;
    final double indent =
        widget.separatorIndent ??
        metrics.rowHorizontal +
            (metrics.desktop ? 28 + 10 : 40 + 12) * metrics.scale;
    final double logical = _logical(_dx);
    final AppleDownloadSwipeAction? leading = widget.leading;
    final AppleDownloadSwipeAction? trailing = widget.trailing;
    final Widget foreground = ColoredBox(
      color: apple.secondaryGroupedBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          widget.child,
          if (!last)
            Padding(
              padding: EdgeInsetsDirectional.only(start: indent),
              child: SizedBox(
                height: fushiHairline(context),
                child: ColoredBox(color: apple.separator),
              ),
            ),
        ],
      ),
    );
    final bool swipeable = leading != null || trailing != null;
    Widget body = foreground;
    if (swipeable) {
      body = Stack(
        children: <Widget>[
          if (logical > 0 && leading != null)
            Positioned.fill(
              child: _actionPane(
                leading,
                apple.accent,
                AlignmentDirectional.centerStart,
              ),
            ),
          if (logical < 0 && trailing != null)
            Positioned.fill(
              child: _actionPane(
                trailing,
                trailing.destructive ? apple.destructive : apple.accent,
                AlignmentDirectional.centerEnd,
              ),
            ),
          Transform.translate(offset: Offset(_dx, 0), child: foreground),
        ],
      );
      // 闭包只捕获这一层的不可变快照：直接读 `body` 会在 builder 运行时读到下面
      // 重新赋值后的外层（Semantics → 本 LayoutBuilder），无限递归、栈溢出。
      final Widget slidable = body;
      body = LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          _width = constraints.maxWidth.isFinite ? constraints.maxWidth : 1;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: _onUpdate,
            onHorizontalDragEnd: _onEnd,
            child: slidable,
          );
        },
      );
      body = Semantics(
        customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
          if (leading != null)
            CustomSemanticsAction(label: leading.label): leading.onTriggered,
          if (trailing != null)
            CustomSemanticsAction(label: trailing.label): trailing.onTriggered,
        },
        child: body,
      );
    }
    return ClipRRect(borderRadius: radius, child: body);
  }
}

/// 组标题（组外，iOS 13 号 secondaryLabel）：「需要处理 · 2」，可折叠时带 chevron，
/// 行尾可挂动作（整组删除）。点按 / Enter 折叠展开（现有分组折叠机制）。
class AppleDownloadSectionHeader extends StatelessWidget {
  const AppleDownloadSectionHeader({
    required this.title,
    this.count,
    this.expanded = true,
    this.onToggle,
    this.detail,
    this.trailing,
    super.key,
  });

  final String title;
  final int? count;
  final bool expanded;
  final VoidCallback? onToggle;

  /// 标题后的补充（折叠时的整体进度等）。
  final String? detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final TextStyle style = metrics.footnoteStyle(context);
    final String text = <String>[
      title,
      if (count != null) '$count',
      if (detail != null) detail!,
    ].join(' · ');
    final Widget label = Row(
      children: <Widget>[
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        if (onToggle != null) ...<Widget>[
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: expanded ? 0.25 : 0,
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            child: FushiIcon(
              FushiIcons.chevronRight,
              size: (style.fontSize ?? 13),
              color: style.color,
            ),
          ),
        ],
      ],
    );
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        metrics.rowHorizontal - 4,
        metrics.groupSpacing,
        metrics.rowHorizontal - 8,
        6,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              expanded: onToggle == null ? null : expanded,
              child: FushiAppleRow(
                onTap: onToggle,
                stateBackground: false,
                borderRadius: FushiAppleRadii.of(context).selectionRadius,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: label,
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Apple 空态（ContentUnavailableView 式）：大图标 + 一句 + 按钮。
class AppleDownloadEmptyState extends StatelessWidget {
  const AppleDownloadEmptyState({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.actionKey,
    super.key,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(icon, size: 54, color: apple.tertiaryLabel),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: metrics
                  .titleStyle(context)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: 12),
              AppleDownloadTextAction(
                key: actionKey,
                label: actionLabel!,
                onTap: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 骨架：一组 4 行占位（行首方块 + 两条灰条），静态 fill 色。
class AppleDownloadSkeleton extends StatelessWidget {
  const AppleDownloadSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final double tile = (metrics.desktop ? 28 : 40) * metrics.scale;
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: apple.fill,
          borderRadius: BorderRadius.circular(height / 2),
        ),
      ),
    );
    return FushiAppleGroupSurface(
      key: const ValueKey<String>('download-task-skeleton'),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < 4; i++)
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: metrics.rowHorizontal,
                vertical: 12,
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: tile,
                    height: tile,
                    decoration: BoxDecoration(
                      color: apple.fill,
                      borderRadius: BorderRadius.circular(tile * 0.22),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        bar(0.7, 12),
                        const SizedBox(height: 8),
                        bar(0.4, 10),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 作品聚焦 token（UISearchToken 式，搜索框下方）：「〈作品〉的任务 ×」。
class AppleDownloadWorkFocusToken extends StatelessWidget {
  const AppleDownloadWorkFocusToken({
    required this.label,
    this.onClear,
    super.key,
  });

  final String label;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final TextStyle style = metrics
        .subtitleStyle(context)
        .copyWith(
          color: apple.label,
          fontSize: (metrics.desktop ? 12 : 15) * metrics.scale,
        );
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        key: const ValueKey<String>('download-task-work-focus'),
        padding: const EdgeInsetsDirectional.only(start: 12, end: 2),
        decoration: ShapeDecoration(
          color: apple.secondaryFill,
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(
              FushiIcons.filterList,
              size: (style.fontSize ?? 15) - 1,
              color: apple.secondaryLabel,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            if (onClear != null)
              FushiIconButton(
                key: const ValueKey<String>('download-task-work-focus-clear'),
                tooltip: t.download_task_work_focus_clear,
                icon: FushiIcons.close,
                size: 16,
                onTap: onClear,
              )
            else
              const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

/// macOS 侧窗格「状态」组的一行（Mail 邮箱式）：名称 + 行尾计数，选中整行
/// secondaryFill 底。
class AppleDownloadFilterRow extends StatelessWidget {
  const AppleDownloadFilterRow({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final TextStyle title = metrics.titleStyle(context);
    return FushiPressScale(
      child: FushiAppleRow(
        onTap: onTap,
        selected: selected,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: metrics.rowMinHeight),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: metrics.rowHorizontal),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: selected
                        ? title.copyWith(fontWeight: FontWeight.w600)
                        : title,
                  ),
                ),
                Text(
                  '$count',
                  style: metrics
                      .subtitleStyle(context)
                      .copyWith(
                        fontSize: metrics.titleSize,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
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
