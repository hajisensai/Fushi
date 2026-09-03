import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_control_item_presentation.dart';
import 'package:fushi/src/media/video/video_custom_action_bindings.dart';
import 'package:fushi/src/media/video/video_custom_action_picker.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/utils.dart';

/// 控制条 9 槽位拖拽编辑器（TODO-274/312 phase 2）。从旧
/// `VideoQuickSettingsSheet._buildControlDragEditor` 系列方法原样抽出为独立控件
/// （阶段 B：面板改 schema 投影，本编辑器以 `SettingsCustomItem` 入 schema、仅播放
/// 中可见），拖拽/驳回/持久化逻辑逐字保留；「重置布局」行改由并列的 schema action
/// 项承载，经 [layout] + didUpdateWidget 同步回本编辑器。
class VideoControlLayoutEditor extends StatefulWidget {
  const VideoControlLayoutEditor({
    required this.layout,
    required this.onLayoutChanged,
    required this.isTouchControls,
    this.customActionBindings = VideoCustomActionBindings.empty,
    this.onCustomActionBindingsChanged,
    super.key,
  });

  /// 页面当前生效布局（外部重置/持久化后经 rebuild 传入，didUpdateWidget 同步）。
  final VideoControlLayout layout;

  /// 槽位/显隐变化后回调：持久化 v2 布局 + 实时生效（调用方负责）。
  final Future<void> Function(VideoControlLayout layout)? onLayoutChanged;

  /// 触屏控件（无右键菜单兜底）：禁止把「设置」按钮拖入 hidden 移除（TODO-554）。
  final bool isTouchControls;

  /// 自定义「快捷键 1..4」按钮当前绑的动作（决定 chip 的图标与名字）。
  final VideoCustomActionBindings customActionBindings;

  /// 改绑回调：点「快捷键 N」chip 选动作后落盘 + 实时生效（调用方负责）。
  /// null = 不提供改绑入口（chip 仍可拖动，只是点不出选择器）。
  final Future<void> Function(VideoCustomActionBindings bindings)?
      onCustomActionBindingsChanged;

  @override
  State<VideoControlLayoutEditor> createState() =>
      _VideoControlLayoutEditorState();
}

class _VideoControlLayoutEditorState extends State<VideoControlLayoutEditor> {
  late VideoControlLayout _controlLayout = widget.layout;
  String? _controlMoveRejectionMessage;

  /// 自定义「快捷键」按钮绑定的本地镜像：与 [_controlLayout] 同款——本地先改、UI 立刻
  /// 反映，同时把新值交给外部落盘（外部回传经 didUpdateWidget 同步回来）。
  late VideoCustomActionBindings _customActionBindings =
      widget.customActionBindings;

  @override
  void didUpdateWidget(VideoControlLayoutEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.customActionBindings != widget.customActionBindings) {
      _customActionBindings = widget.customActionBindings;
    }
    if (oldWidget.layout != widget.layout) {
      _controlLayout = widget.layout;
      // 外部重置/换布局后清掉上一轮的拖拽驳回提示（旧 sheet 行为）：提示描述的
      // 是旧布局上被拒的那次拖拽，布局已换仍挂着会误导。
      _controlMoveRejectionMessage = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildControlStagePreview(),
          if (_controlMoveRejectionMessage != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Text(
              _controlMoveRejectionMessage!,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: cs.error,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
          SizedBox(height: tokens.spacing.gap),
          _buildControlPalette(),
          SizedBox(height: tokens.spacing.gap),
          _buildHiddenSlotTray(),
        ],
      ),
    );
  }

  Widget _buildControlStagePreview() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < 480;
        if (compact) {
          return DecoratedBox(
            key: const ValueKey<String>('video-control-editor-preview'),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: tokens.radii.controlRadius,
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.gap),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _buildCompactSlotGrid(<VideoControlSlot>[
                    VideoControlSlot.topLeft,
                    VideoControlSlot.topCenter,
                    VideoControlSlot.topRight,
                  ]),
                  SizedBox(height: tokens.spacing.gap),
                  _buildCompactSlotGrid(<VideoControlSlot>[
                    VideoControlSlot.screenLeft,
                    VideoControlSlot.screenRight,
                  ]),
                  SizedBox(height: tokens.spacing.gap),
                  _buildCompactSlotGrid(<VideoControlSlot>[
                    VideoControlSlot.bottomLeft,
                    VideoControlSlot.bottomCenter,
                    VideoControlSlot.bottomRight,
                  ]),
                ],
              ),
            ),
          );
        }

        final double stageWidth = constraints.maxWidth;
        final double stageHeight = math.min(
          420,
          math.max(260, stageWidth * 9 / 16),
        );
        return SizedBox(
          width: stageWidth,
          height: stageHeight,
          child: DecoratedBox(
            key: const ValueKey<String>('video-control-editor-preview'),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: tokens.radii.controlRadius,
              border: Border.all(color: cs.outlineVariant),
            ),
            child: ClipRRect(
              borderRadius: tokens.radii.controlRadius,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints preview) {
                  final double sideWidth =
                      math.min(224, math.max(128, preview.maxWidth * 0.24));
                  final double centerWidth =
                      math.min(236, math.max(128, preview.maxWidth * 0.22));
                  const double inset = 10;
                  return Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: <Color>[
                                cs.surfaceContainerHigh,
                                cs.surfaceContainerHighest,
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: inset,
                        left: inset,
                        width: sideWidth,
                        child: _buildSlotRegion(VideoControlSlot.topLeft),
                      ),
                      Positioned(
                        top: inset,
                        right: inset,
                        width: sideWidth,
                        child: _buildSlotRegion(VideoControlSlot.topRight),
                      ),
                      Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: inset),
                          child: SizedBox(
                            width: centerWidth,
                            child: _buildSlotRegion(
                              VideoControlSlot.topCenter,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: inset,
                        top: 0,
                        bottom: 0,
                        width: sideWidth,
                        child: Center(
                          child: _buildSlotRegion(VideoControlSlot.screenLeft),
                        ),
                      ),
                      Positioned(
                        right: inset,
                        top: 0,
                        bottom: 0,
                        width: sideWidth,
                        child: Center(
                          child: _buildSlotRegion(VideoControlSlot.screenRight),
                        ),
                      ),
                      Positioned(
                        left: inset,
                        bottom: inset,
                        width: sideWidth,
                        child: _buildSlotRegion(VideoControlSlot.bottomLeft),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: inset),
                          child: SizedBox(
                            width: centerWidth,
                            child: _buildSlotRegion(
                              VideoControlSlot.bottomCenter,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: inset,
                        bottom: inset,
                        width: sideWidth,
                        child: _buildSlotRegion(VideoControlSlot.bottomRight),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCompactSlotGrid(List<VideoControlSlot> slots) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final double gap = tokens.spacing.gap;
        final double itemWidth = constraints.maxWidth < 260
            ? constraints.maxWidth
            : (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final VideoControlSlot slot in slots)
              SizedBox(
                width: itemWidth,
                child: _buildSlotRegion(slot, growToContent: true),
              ),
          ],
        );
      },
    );
  }

  Widget _buildControlPalette() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(
              Icons.dashboard_customize_outlined,
              size: 18,
              color: cs.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t.video_control_palette_title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final VideoControlItem item
                in VideoControlItem.customizableItems)
              _buildDraggableControlChip(
                item,
                sourceSlot: null,
                sourceIndex: null,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildHiddenSlotTray() {
    return _buildSlotRegion(VideoControlSlot.hidden, tray: true);
  }

  Widget _buildSlotRegion(
    VideoControlSlot slot, {
    bool tray = false,
    bool growToContent = false,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<({VideoControlItem item, int sourceIndex})> entries =
        _slotChipEntries(slot);
    final bool removalSlot = slot == VideoControlSlot.hidden;
    return DragTarget<VideoControlDragData>(
      key: ValueKey<String>('video-control-edit-slot-${slot.storageValue}'),
      onWillAcceptWithDetails:
          (DragTargetDetails<VideoControlDragData> details) =>
              _handleControlDragWillAccept(details.data, slot),
      onAcceptWithDetails: (DragTargetDetails<VideoControlDragData> details) {
        _moveControlItem(
          details.data,
          slot,
          targetIndex: _controlLayout.itemsIn(slot).length,
        );
      },
      builder: (
        BuildContext context,
        List<VideoControlDragData?> candidate,
        List<dynamic> rejected,
      ) {
        final bool highlighted = candidate.isNotEmpty;
        final bool rejecting = rejected.isNotEmpty;
        final String? rejectionMessage =
            rejecting ? _controlMoveRejectionMessage : null;
        final Color borderColor = rejecting
            ? cs.error
            : highlighted
                ? cs.primary
                : cs.outlineVariant;
        final Widget chipArea = entries.isEmpty
            ? SizedBox(
                height: 32,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Icon(
                    removalSlot
                        ? Icons.remove_circle_outline
                        : Icons.add_circle_outline,
                    size: 18,
                    color: highlighted
                        ? cs.onPrimaryContainer
                        : cs.onSurfaceVariant,
                  ),
                ),
              )
            : Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final ({VideoControlItem item, int sourceIndex}) entry
                      in entries)
                    _buildPlacedControlChip(
                      entry.item,
                      sourceSlot: slot,
                      sourceIndex: entry.sourceIndex,
                    ),
                ],
              );
        final BoxConstraints containerConstraints = growToContent
            ? BoxConstraints(minHeight: tray ? 64 : 58)
            : BoxConstraints(
                minHeight: tray ? 64 : 58,
                maxHeight: tray ? 160 : 148,
              );
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: containerConstraints,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: highlighted
                ? cs.primaryContainer.withValues(alpha: 0.88)
                : cs.surface.withValues(alpha: tray ? 1 : 0.88),
            borderRadius: tokens.radii.controlRadius,
            border: Border.all(
              color: borderColor,
              width: highlighted || rejecting ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _controlSlotLabel(slot),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color:
                      highlighted ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (rejectionMessage != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  rejectionMessage,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              if (growToContent)
                chipArea
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: chipArea,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  List<({VideoControlItem item, int sourceIndex})> _slotChipEntries(
    VideoControlSlot slot,
  ) {
    final List<VideoControlItem> items = _controlLayout.itemsIn(slot);
    return <({VideoControlItem item, int sourceIndex})>[
      for (int index = 0; index < items.length; index++)
        if (items[index].isChipRenderable)
          (item: items[index], sourceIndex: index),
    ];
  }

  Widget _buildPlacedControlChip(
    VideoControlItem item, {
    required VideoControlSlot sourceSlot,
    required int sourceIndex,
  }) {
    return DragTarget<VideoControlDragData>(
      onWillAcceptWithDetails:
          (DragTargetDetails<VideoControlDragData> details) =>
              _handleControlDragWillAccept(details.data, sourceSlot),
      onAcceptWithDetails: (DragTargetDetails<VideoControlDragData> details) {
        _moveControlItem(
          details.data,
          sourceSlot,
          targetIndex: sourceIndex,
        );
      },
      builder: (
        BuildContext context,
        List<VideoControlDragData?> candidate,
        List<dynamic> rejected,
      ) {
        return _buildDraggableControlChip(
          item,
          sourceSlot: sourceSlot,
          sourceIndex: sourceIndex,
          highlighted: candidate.isNotEmpty,
        );
      },
    );
  }

  Widget _buildDraggableControlChip(
    VideoControlItem item, {
    required VideoControlSlot? sourceSlot,
    required int? sourceIndex,
    bool highlighted = false,
  }) {
    final Widget chip = _controlChipBody(
      item,
      sourceSlot: sourceSlot,
      sourceIndex: sourceIndex,
      dragging: false,
      highlighted: highlighted,
    );
    // 「快捷键 N」槽位：点一下选它执行哪个动作（拖动仍然照常改位置——Draggable 用的是
    // 即时拖拽识别器，与 onTap 在手势竞技场里按「有没有位移」自然分流，不互相吃事件）。
    // 这是本功能唯一的配置入口：按钮就在编辑器里，点它配、拖它摆，不用去别的页面找。
    if (item.isCustomAction && widget.onCustomActionBindingsChanged != null) {
      return GestureDetector(
        onTap: () => unawaited(_pickCustomAction(item)),
        child: _wrapDraggableChip(chip, item, sourceSlot, sourceIndex),
      );
    }
    return _wrapDraggableChip(chip, item, sourceSlot, sourceIndex);
  }

  Widget _wrapDraggableChip(
    Widget chip,
    VideoControlItem item,
    VideoControlSlot? sourceSlot,
    int? sourceIndex,
  ) {
    return Draggable<VideoControlDragData>(
      data: VideoControlDragData(
        item: item,
        sourceSlot: sourceSlot,
        sourceIndex: sourceIndex,
      ),
      hitTestBehavior: HitTestBehavior.opaque,
      feedback: Material(
        color: Colors.transparent,
        child: _controlChipBody(
          item,
          sourceSlot: sourceSlot,
          sourceIndex: sourceIndex,
          dragging: true,
          highlighted: false,
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: chip),
      onDraggableCanceled: (_, __) => _handleControlDragCanceled(item),
      child: chip,
    );
  }

  /// 点「快捷键 N」chip：选它执行哪个动作。选完立即落盘 + 生效，没有「保存」步骤。
  ///
  /// 弹窗本体走共享的 [showVideoCustomActionPicker]——播放器控制条上直接点空按钮走的
  /// 是同一个入口，两处列表/顺序/选中态必然一致。
  Future<void> _pickCustomAction(VideoControlItem item) async {
    final int? slotIndex = item.customActionSlotIndex;
    final Future<void> Function(VideoCustomActionBindings)? onChanged =
        widget.onCustomActionBindingsChanged;
    if (slotIndex == null || onChanged == null) return;
    final ShortcutAction? current = _customActionBindings.actionAt(slotIndex);
    final VideoCustomActionPick? pick = await showVideoCustomActionPicker(
      context: context,
      slotNumber: slotIndex + 1,
      current: current,
    );
    // null = 用户点外部 / 返回键取消（区别于显式选了「不绑定」，那是
    // `VideoCustomActionPick(null)`）——取消必须保持原绑定不动。
    if (pick == null || !mounted) return;
    final VideoCustomActionBindings next =
        _customActionBindings.withAction(slotIndex, pick.action);
    if (next == _customActionBindings) return;
    setState(() => _customActionBindings = next);
    await onChanged(next);
  }

  void _handleControlDragCanceled(VideoControlItem item) {
    final String? message = switch (item) {
      VideoControlItem.volume => t.video_control_reject_volume_bottom,
      _ => _controlMoveRejectionMessage,
    };
    if (message == null || _controlMoveRejectionMessage == message) return;
    setState(() => _controlMoveRejectionMessage = message);
  }

  Widget _controlChipBody(
    VideoControlItem item, {
    required VideoControlSlot? sourceSlot,
    required int? sourceIndex,
    required bool dragging,
    required bool highlighted,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String label = videoControlItemLabel(
      item,
      context,
      bindings: _customActionBindings,
    );
    final Color background =
        highlighted ? cs.primaryContainer : cs.secondaryContainer;
    final Color foreground =
        highlighted ? cs.onPrimaryContainer : cs.onSecondaryContainer;
    final String sourceSlotKey = sourceSlot?.storageValue ?? 'palette';
    final String sourceIndexKey = sourceIndex?.toString() ?? 'palette';
    final Widget body = SizedBox.square(
      dimension: 36,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: tokens.radii.controlRadius,
          border: Border.all(
            color: highlighted ? cs.primary : cs.outlineVariant,
            width: highlighted ? 1.5 : 1,
          ),
          boxShadow: dragging
              ? <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.24),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Icon(
          videoControlItemIcon(item, bindings: _customActionBindings),
          size: 18,
          color: foreground,
        ),
      ),
    );
    return Tooltip(
      message: label,
      child: Semantics(
        key: dragging
            ? null
            : ValueKey<String>(
                'video-control-chip-${item.storageValue}-$sourceSlotKey-$sourceIndexKey',
              ),
        label: label,
        button: true,
        container: true,
        child: Listener(
          key: dragging
              ? null
              : ValueKey<String>(
                  'video-control-drag-chip-${item.storageValue}-$sourceSlotKey-$sourceIndexKey',
                ),
          behavior: HitTestBehavior.opaque,
          child: ExcludeSemantics(child: body),
        ),
      ),
    );
  }

  bool _canAcceptControlPayload(
    VideoControlDragData payload,
    VideoControlSlot target,
  ) {
    final VideoControlItem item = payload.item;
    if (!item.isChipRenderable) return false;
    if (!item.canMoveToSlot(
      target,
      isTouchControls: widget.isTouchControls,
    )) {
      return false;
    }
    if (payload.sourceSlot == target) return true;
    return !_controlLayout.itemsIn(target).contains(item);
  }

  bool _handleControlDragWillAccept(
    VideoControlDragData payload,
    VideoControlSlot target,
  ) {
    final bool accepted = _canAcceptControlPayload(payload, target);
    final String? message =
        accepted ? null : _controlRejectionMessage(payload.item, target);
    if (_controlMoveRejectionMessage != message) {
      setState(() => _controlMoveRejectionMessage = message);
    }
    return accepted;
  }

  String? _controlRejectionMessage(
    VideoControlItem item,
    VideoControlSlot target,
  ) {
    if (item == VideoControlItem.volume && !item.canMoveToSlot(target)) {
      return t.video_control_reject_volume_bottom;
    }
    if ((item.pinnedRequired ||
            (widget.isTouchControls && item.pinnedOnTouch)) &&
        target == VideoControlSlot.hidden) {
      return t.video_control_reject_required;
    }
    if (!item.canMoveToSlot(
      target,
      isTouchControls: widget.isTouchControls,
    )) {
      return t.video_control_reject_unavailable;
    }
    return null;
  }

  void _moveControlItem(
    VideoControlDragData payload,
    VideoControlSlot target, {
    int? targetIndex,
  }) {
    final VideoControlLayout next = _controlLayout.moveDraggedItem(
      payload,
      target,
      targetIndex: targetIndex,
    );
    if (next == _controlLayout) return;
    setState(() {
      _controlLayout = next;
      _controlMoveRejectionMessage = null;
    });
    final Future<void> Function(VideoControlLayout layout)? callback =
        widget.onLayoutChanged;
    if (callback != null) {
      unawaited(callback(next));
    }
  }

  String _controlSlotLabel(VideoControlSlot slot) {
    switch (slot) {
      case VideoControlSlot.topLeft:
        return t.video_control_slot_top_left;
      case VideoControlSlot.topRight:
        return t.video_control_slot_top_right;
      case VideoControlSlot.bottomLeft:
        return t.video_control_slot_bottom_left;
      case VideoControlSlot.bottomCenter:
        return t.video_control_slot_bottom_center;
      case VideoControlSlot.bottomRight:
        return t.video_control_slot_bottom_right;
      case VideoControlSlot.screenLeft:
        return t.video_control_slot_screen_left;
      case VideoControlSlot.screenRight:
        return t.video_control_slot_screen_right;
      case VideoControlSlot.hidden:
        return t.video_control_slot_hidden;
      case VideoControlSlot.topCenter:
        return t.video_control_slot_top_center;
    }
  }
}
