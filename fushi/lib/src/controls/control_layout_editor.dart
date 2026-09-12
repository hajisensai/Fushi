import 'package:flutter/material.dart';

import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 由 [ControlLayoutEditor] 交给宿主的「造一个槽位放置区」入口：宿主在舞台预览里
/// 按自己的几何排布槽位，每个槽位调它一次拿到可投放区域。
typedef ControlSlotRegionBuilder<S> = Widget Function(
  S slot, {
  bool growToContent,
});

/// 宿主描述舞台预览：拿到 [ControlSlotRegionBuilder]，把各槽位排成播放器 / 阅读器
/// 的方位图。hidden 槽不在舞台上（编辑器自己画成底部托盘）。
typedef ControlStageBuilder<S> = Widget Function(
  BuildContext context,
  ControlSlotRegionBuilder<S> buildSlotRegion,
);

/// 控制按钮布局拖拽编辑器的泛型骨架：舞台预览（宿主排布）+ 调色板 + 隐藏托盘 +
/// 拖拽驳回提示。所有域知识（图标 / 标签 / 槽位名 / 驳回文案 / 舞台几何 / chip
/// 附加交互）由参数注入，本控件只管拖放状态机与 [ControlLayout] 写操作。
///
/// 视频页 `VideoControlLayoutEditor` 是第一个宿主；阅读器工具栏编辑器复用同一份。
class ControlLayoutEditor<S extends ControlSlotSpec,
    I extends ControlItemSpec<S>> extends StatefulWidget {
  const ControlLayoutEditor({
    required this.layout,
    required this.onLayoutChanged,
    required this.isTouchControls,
    required this.paletteItems,
    required this.paletteTitle,
    required this.stageBuilder,
    required this.iconOf,
    required this.labelOf,
    required this.slotLabelOf,
    required this.rejectionMessageOf,
    this.dragCanceledMessageOf,
    this.canRenderChip,
    this.wrapChip,
    this.keyPrefix = 'control',
    super.key,
  });

  /// 当前生效布局（外部重置 / 持久化后经 rebuild 传入，didUpdateWidget 同步）。
  final ControlLayout<S, I> layout;

  /// 槽位 / 显隐变化后回调（持久化 + 实时生效由宿主负责）。
  final void Function(ControlLayout<S, I> layout)? onLayoutChanged;

  /// 触屏控件：[ControlItemSpec.pinnedOnTouch] 的按钮禁止拖入 hidden。
  final bool isTouchControls;

  /// 「全部按钮」调色板内容（拖出 = 新增一份副本）。
  final List<I> paletteItems;

  final String paletteTitle;

  final ControlStageBuilder<S> stageBuilder;

  final IconData Function(I item) iconOf;
  final String Function(I item) labelOf;
  final String Function(S slot) slotLabelOf;

  /// 拖放被拒时的提示文案（null = 不提示）。宿主按自己的规则解释为什么拒。
  final String? Function(I item, S target) rejectionMessageOf;

  /// 拖拽在任何目标外松手（Draggable 取消）时的提示；null / 返回 null = 不提示。
  final String? Function(I item)? dragCanceledMessageOf;

  /// 哪些按钮能画成单个 chip；null = 全部。画不成 chip 的按钮不出现在槽位里也不接受
  /// 拖放（例如视频的时间文本）。
  final bool Function(I item)? canRenderChip;

  /// 给 chip（已含 Draggable）套一层宿主交互，例如点击改绑自定义动作。
  final Widget Function(BuildContext context, I item, Widget chip)? wrapChip;

  /// Widget key 前缀：`<prefix>-edit-slot-<slot>` / `<prefix>-chip-…` /
  /// `<prefix>-drag-chip-…`，宿主测试按这些 key 定位。
  final String keyPrefix;

  @override
  State<ControlLayoutEditor<S, I>> createState() =>
      _ControlLayoutEditorState<S, I>();
}

class _ControlLayoutEditorState<S extends ControlSlotSpec,
    I extends ControlItemSpec<S>> extends State<ControlLayoutEditor<S, I>> {
  late ControlLayout<S, I> _layout = widget.layout;
  String? _rejectionMessage;

  S get _hiddenSlot => _layout.scheme.hiddenSlot;

  bool _chipRenderable(I item) => widget.canRenderChip?.call(item) ?? true;

  @override
  void didUpdateWidget(ControlLayoutEditor<S, I> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout != widget.layout) {
      _layout = widget.layout;
      // 外部重置 / 换布局后清掉上一轮的拖拽驳回提示：提示描述的是旧布局上被拒的
      // 那次拖拽，布局已换仍挂着会误导。
      _rejectionMessage = null;
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
          widget.stageBuilder(context, _buildSlotRegion),
          if (_rejectionMessage != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Text(
              _rejectionMessage!,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: cs.error,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
          SizedBox(height: tokens.spacing.gap),
          _buildPalette(),
          SizedBox(height: tokens.spacing.gap),
          _buildSlotRegion(_hiddenSlot, tray: true),
        ],
      ),
    );
  }

  Widget _buildPalette() {
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
                widget.paletteTitle,
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
            for (final I item in widget.paletteItems)
              _buildDraggableChip(item, sourceSlot: null, sourceIndex: null),
          ],
        ),
      ],
    );
  }

  Widget _buildSlotRegion(
    S slot, {
    bool tray = false,
    bool growToContent = false,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<({I item, int sourceIndex})> entries = _slotChipEntries(slot);
    final bool removalSlot = slot == _hiddenSlot;
    return DragTarget<ControlDragData<S, I>>(
      key: ValueKey<String>(
        '${widget.keyPrefix}-edit-slot-${slot.storageValue}',
      ),
      onWillAcceptWithDetails:
          (DragTargetDetails<ControlDragData<S, I>> details) =>
              _handleDragWillAccept(details.data, slot),
      onAcceptWithDetails: (DragTargetDetails<ControlDragData<S, I>> details) {
        _moveItem(
          details.data,
          slot,
          targetIndex: _layout.itemsIn(slot).length,
        );
      },
      builder: (
        BuildContext context,
        List<ControlDragData<S, I>?> candidate,
        List<dynamic> rejected,
      ) {
        final bool highlighted = candidate.isNotEmpty;
        final bool rejecting = rejected.isNotEmpty;
        final String? rejectionMessage = rejecting ? _rejectionMessage : null;
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
                  for (final ({I item, int sourceIndex}) entry in entries)
                    _buildPlacedChip(
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
                widget.slotLabelOf(slot),
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

  List<({I item, int sourceIndex})> _slotChipEntries(S slot) {
    final List<I> items = _layout.itemsIn(slot);
    return <({I item, int sourceIndex})>[
      for (int index = 0; index < items.length; index++)
        if (_chipRenderable(items[index]))
          (item: items[index], sourceIndex: index),
    ];
  }

  Widget _buildPlacedChip(
    I item, {
    required S sourceSlot,
    required int sourceIndex,
  }) {
    return DragTarget<ControlDragData<S, I>>(
      onWillAcceptWithDetails:
          (DragTargetDetails<ControlDragData<S, I>> details) =>
              _handleDragWillAccept(details.data, sourceSlot),
      onAcceptWithDetails: (DragTargetDetails<ControlDragData<S, I>> details) {
        _moveItem(details.data, sourceSlot, targetIndex: sourceIndex);
      },
      builder: (
        BuildContext context,
        List<ControlDragData<S, I>?> candidate,
        List<dynamic> rejected,
      ) {
        return _buildDraggableChip(
          item,
          sourceSlot: sourceSlot,
          sourceIndex: sourceIndex,
          highlighted: candidate.isNotEmpty,
        );
      },
    );
  }

  Widget _buildDraggableChip(
    I item, {
    required S? sourceSlot,
    required int? sourceIndex,
    bool highlighted = false,
  }) {
    final Widget chip = _chipBody(
      item,
      sourceSlot: sourceSlot,
      sourceIndex: sourceIndex,
      dragging: false,
      highlighted: highlighted,
    );
    final Widget draggable = Draggable<ControlDragData<S, I>>(
      data: ControlDragData<S, I>(
        item: item,
        sourceSlot: sourceSlot,
        sourceIndex: sourceIndex,
      ),
      hitTestBehavior: HitTestBehavior.opaque,
      feedback: Material(
        color: Colors.transparent,
        child: _chipBody(
          item,
          sourceSlot: sourceSlot,
          sourceIndex: sourceIndex,
          dragging: true,
          highlighted: false,
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: chip),
      onDraggableCanceled: (_, __) => _handleDragCanceled(item),
      child: chip,
    );
    return widget.wrapChip?.call(context, item, draggable) ?? draggable;
  }

  void _handleDragCanceled(I item) {
    final String? message = widget.dragCanceledMessageOf?.call(item);
    if (message == null || _rejectionMessage == message) return;
    setState(() => _rejectionMessage = message);
  }

  Widget _chipBody(
    I item, {
    required S? sourceSlot,
    required int? sourceIndex,
    required bool dragging,
    required bool highlighted,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String label = widget.labelOf(item);
    final Color background =
        highlighted ? cs.primaryContainer : cs.secondaryContainer;
    final Color foreground =
        highlighted ? cs.onPrimaryContainer : cs.onSecondaryContainer;
    final String sourceSlotKey = sourceSlot?.storageValue ?? 'palette';
    final String sourceIndexKey = sourceIndex?.toString() ?? 'palette';
    final String keySuffix =
        '${item.storageValue}-$sourceSlotKey-$sourceIndexKey';
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
        child: Icon(widget.iconOf(item), size: 18, color: foreground),
      ),
    );
    return Tooltip(
      message: label,
      child: Semantics(
        key: dragging
            ? null
            : ValueKey<String>('${widget.keyPrefix}-chip-$keySuffix'),
        label: label,
        button: true,
        container: true,
        child: Listener(
          key: dragging
              ? null
              : ValueKey<String>('${widget.keyPrefix}-drag-chip-$keySuffix'),
          behavior: HitTestBehavior.opaque,
          child: ExcludeSemantics(child: body),
        ),
      ),
    );
  }

  bool _canAcceptPayload(ControlDragData<S, I> payload, S target) {
    final I item = payload.item;
    if (!_chipRenderable(item)) return false;
    if (!item.canMoveToSlot(target, isTouchControls: widget.isTouchControls)) {
      return false;
    }
    if (payload.sourceSlot == target) return true;
    return !_layout.itemsIn(target).contains(item);
  }

  bool _handleDragWillAccept(ControlDragData<S, I> payload, S target) {
    final bool accepted = _canAcceptPayload(payload, target);
    final String? message =
        accepted ? null : widget.rejectionMessageOf(payload.item, target);
    if (_rejectionMessage != message) {
      setState(() => _rejectionMessage = message);
    }
    return accepted;
  }

  void _moveItem(
    ControlDragData<S, I> payload,
    S target, {
    int? targetIndex,
  }) {
    final ControlLayout<S, I> next =
        _layout.moveDraggedItem(payload, target, targetIndex: targetIndex);
    if (next == _layout) return;
    setState(() {
      _layout = next;
      _rejectionMessage = null;
    });
    widget.onLayoutChanged?.call(next);
  }
}
