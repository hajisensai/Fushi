import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_control_item_presentation.dart';
import 'package:fushi/src/media/video/video_custom_action_bindings.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart'
    show videoM3eFloatingColor;
import 'package:fushi/src/media/video/video_side_panel.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';

class VideoControlLayoutEditOverlay extends StatefulWidget {
  const VideoControlLayoutEditOverlay({
    required this.layout,
    required this.onLayoutChanged,
    required this.onClose,
    this.isTouchControls = false,
    this.customActionBindings = VideoCustomActionBindings.empty,
    super.key,
  });

  final VideoControlLayout layout;
  final Future<void> Function(VideoControlLayout layout) onLayoutChanged;
  final VoidCallback onClose;

  /// 自定义「快捷键 1..4」按钮当前绑的动作：决定本覆盖层里那几个 chip 显示成哪个动作
  /// 的图标与名字。本覆盖层**只管摆位置、不改绑**（它已经是个拖拽密集的界面，再叠一层
  /// tap 语义容易误触）；改绑走设置里的 [VideoControlLayoutEditor]。
  final VideoCustomActionBindings customActionBindings;

  /// Touch surface (no right-click context menu fallback): forbids removing the
  /// sole in-player settings entry so the user cannot soft-lock the controls
  /// editor out of reach (TODO-554).
  final bool isTouchControls;

  @override
  State<VideoControlLayoutEditOverlay> createState() =>
      _VideoControlLayoutEditOverlayState();
}

class _VideoControlLayoutEditOverlayState
    extends State<VideoControlLayoutEditOverlay> {
  /// Buttons users can directly rearrange on the video surface.
  static List<VideoControlItem> get _onVideoDraggableItems =>
      VideoControlItem.customizableItems;

  /// 编辑器暴露的槽位表 —— 直接取自唯一真相源。
  ///
  /// 此前这里硬编码了一份**与 [VideoControlSlot.editableSlots] 不一致**的副本
  /// （多一个 topCenter），而那个常量零生产消费方。两份表谁也管不住谁，新增槽位
  /// 时必然漏改其中一处。
  static List<VideoControlSlot> get _editorSlots =>
      VideoControlSlot.editableSlots;

  late VideoControlLayout _layout = widget.layout;
  bool _dirty = false;

  @override
  void didUpdateWidget(VideoControlLayoutEditOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dirty && oldWidget.layout != widget.layout) {
      _layout = widget.layout;
    }
  }

  /// 本覆盖层的配色主题：M3E 下与设置侧板同一份播放器面板中性主题
  /// （[videoM3ePanelTheme]：灰阶容器、白字、强调色仍是 app 主色），Apple / 墨水屏
  /// 原样。槽位与 chip 的颜色都从这里取——它们画在面板表面之外（直接压在画面
  /// scrim 上，拖拽反馈还在 Overlay 里），拿不到面板表面注入的 Theme。
  ThemeData get _theme {
    final ThemeData base = Theme.of(context);
    return videoM3ePanelNeutral(context) ? videoM3ePanelTheme(base) : base;
  }

  /// 槽位 / 调色板的错峰进场（M3E spring；墨水屏与减弱动态效果下直接到位）。
  Widget _enter(int index, Widget child) =>
      FushiStaggeredEntrance(index: index, child: child);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.34),
      child: SafeArea(
        child: FushiEntranceScope(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool compact =
                  constraints.maxWidth < 760 || constraints.maxHeight < 460;
              if (compact) return _buildCompactLayout(constraints);
              return _buildSpatialLayout(constraints);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSpatialLayout(BoxConstraints constraints) {
    final double sideWidth = math.min(
      216,
      math.max(148, constraints.maxWidth * 0.22),
    );
    final double centerWidth = math.min(
      320,
      math.max(236, constraints.maxWidth * 0.3),
    );
    final double paletteWidth = math.min(
      420,
      math.max(260, constraints.maxWidth - sideWidth * 2 - 72),
    );
    final double centerLeft = (constraints.maxWidth - centerWidth) / 2;
    final double paletteLeft = (constraints.maxWidth - paletteWidth) / 2;
    final double paletteHeight = math.min(
      160,
      math.max(96, constraints.maxHeight - 340),
    );

    return Stack(
      children: <Widget>[
        Positioned(
          top: 12,
          left: 12,
          width: sideWidth,
          child: _enter(0, _buildSlotRegion(VideoControlSlot.topLeft)),
        ),
        Positioned(
          top: 12,
          right: 12,
          width: sideWidth,
          child: _enter(2, _buildSlotRegion(VideoControlSlot.topRight)),
        ),
        Positioned(
          top: 12,
          left: centerLeft,
          width: centerWidth,
          child: _enter(1, _buildSlotRegion(VideoControlSlot.topCenter)),
        ),
        Positioned(
          top: 108,
          left: paletteLeft,
          width: paletteWidth,
          child: _enter(
            3,
            _buildPalette(maxWidth: paletteWidth, maxHeight: paletteHeight),
          ),
        ),
        Positioned(
          left: paletteLeft,
          right: paletteLeft,
          bottom: 108,
          child: _enter(
            4,
            _buildSlotRegion(VideoControlSlot.hidden, tray: true),
          ),
        ),
        Positioned(
          left: 12,
          top: 0,
          bottom: 0,
          width: sideWidth,
          child: Center(
            child: _enter(4, _buildSlotRegion(VideoControlSlot.screenLeft)),
          ),
        ),
        Positioned(
          right: 12,
          top: 0,
          bottom: 0,
          width: sideWidth,
          child: Center(
            child: _enter(4, _buildSlotRegion(VideoControlSlot.screenRight)),
          ),
        ),
        Positioned(
          left: 12,
          bottom: 12,
          width: sideWidth,
          child: _enter(5, _buildSlotRegion(VideoControlSlot.bottomLeft)),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              width: centerWidth,
              child: _enter(6, _buildSlotRegion(VideoControlSlot.bottomCenter)),
            ),
          ),
        ),
        Positioned(
          right: 12,
          bottom: 12,
          width: sideWidth,
          child: _enter(7, _buildSlotRegion(VideoControlSlot.bottomRight)),
        ),
      ],
    );
  }

  Widget _buildCompactLayout(BoxConstraints constraints) {
    final double availableWidth = math.max(0, constraints.maxWidth - 24);
    final double tileWidth =
        availableWidth >= 440 ? (availableWidth - 8) / 2 : availableWidth;
    final double paletteMaxHeight = math.min(
      200,
      math.max(0, constraints.maxHeight - 40),
    );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: <Widget>[
          _enter(
            0,
            _buildCompactPalette(
              maxWidth: availableWidth,
              maxHeight: paletteMaxHeight,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final (int index, VideoControlSlot slot)
                      in _editorSlots.indexed)
                    SizedBox(
                      width: tileWidth,
                      child: _enter(
                        index + 1,
                        _buildSlotRegion(
                          slot,
                          tray: slot == VideoControlSlot.hidden,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactPalette({
    required double maxWidth,
    required double maxHeight,
  }) {
    final ColorScheme cs = _theme.colorScheme;
    final Widget chipList = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final VideoControlItem item in _onVideoDraggableItems)
          _buildDraggableControlChip(
            item,
            sourceSlot: null,
            sourceIndex: null,
          ),
      ],
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      child: SizedBox(
        height: maxHeight,
        // 与设置侧板同一枚浮层表面（M3E 中性深色 / Apple 玻璃 / 墨水屏描边）。
        child: VideoFloatingPanelSurface(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 12),
            child: Column(
              children: <Widget>[
                SizedBox(
                  height: 48,
                  // 按钮工具条（取消/保存/标题），不含可拖 chip——放开鼠标拖动
                  // 滚动不会与下方调色板的 Draggable 抢手势。
                  child: HorizontalDragScrollable(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          FushiIcon(
                            FushiIcons.dashboardCustomize,
                            size: 20,
                            color: cs.primary,
                          ),
                          const SizedBox(width: 4),
                          FushiTextButton(
                            onPressed: _cancelDraft,
                            child: Text(t.dialog_cancel),
                          ),
                          const SizedBox(width: 2),
                          FushiFilledButton(
                            onPressed: _saveDraft,
                            child: Text(t.dialog_save),
                          ),
                          FushiIconButtonControl(
                            tooltip: MaterialLocalizations.of(context)
                                .closeButtonTooltip,
                            icon: const FushiIcon(FushiIcons.close),
                            onPressed: _cancelDraft,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            t.video_control_palette_title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.fushiType.titleMediumEmphasized
                                .copyWith(color: cs.onSurface),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(child: chipList),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPalette({double maxWidth = 420, double? maxHeight}) {
    final ColorScheme cs = _theme.colorScheme;
    final bool tightHeight = maxHeight != null && maxHeight < 220;
    final Widget chipList = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final VideoControlItem item in _onVideoDraggableItems)
          _buildDraggableControlChip(
            item,
            sourceSlot: null,
            sourceIndex: null,
          ),
      ],
    );
    // 与设置侧板同一枚浮层表面（M3E 中性深色 / Apple 玻璃 / 墨水屏描边）。
    final Widget panel = VideoFloatingPanelSurface(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(
          mainAxisSize: maxHeight == null ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                FushiIcon(
                  FushiIcons.dashboardCustomize,
                  size: 20,
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.video_control_palette_title,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.titleMediumEmphasized.copyWith(
                      color: cs.onSurface,
                    ),
                  ),
                ),
                FushiIconButtonControl(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const FushiIcon(FushiIcons.close),
                  onPressed: _cancelDraft,
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (maxHeight == null)
              chipList
            else
              Expanded(child: SingleChildScrollView(child: chipList)),
            const SizedBox(height: 6),
            if (!tightHeight) ...<Widget>[
              Text(
                t.video_control_palette_hint,
                style: context.fushiType.bodySmall.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: <Widget>[
                  FushiTextButton(
                    onPressed: _cancelDraft,
                    child: Text(t.dialog_cancel),
                  ),
                  FushiFilledButton(
                    onPressed: _saveDraft,
                    child: Text(t.dialog_save),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final Widget boundedPanel =
        maxHeight == null ? panel : SizedBox(height: maxHeight, child: panel);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth,
        maxHeight: maxHeight ?? double.infinity,
      ),
      child: boundedPanel,
    );
  }

  Widget _buildSlotRegion(VideoControlSlot slot, {bool tray = false}) {
    final ColorScheme cs = _theme.colorScheme;
    final bool neutral = videoM3ePanelNeutral(context);
    final FushiSpringSpec colorSpring = context.fushiMotion.effectsFast;
    final TextStyle labelStyle = context.fushiType.labelMediumEmphasized;
    final TextStyle hintStyle = context.fushiType.bodySmall;
    // M3E：槽位是与面板同色的中性浮层块（无描边），拖入时换成 secondaryContainer
    // tonal 色块；Apple / 墨水屏保持半透明表面 + 细描边。
    final Color restColor = neutral
        ? videoM3eFloatingColor(Theme.of(context).colorScheme)
        : cs.surface.withValues(alpha: 0.86);
    final Color restBorder = neutral ? Colors.transparent : cs.outlineVariant;
    final List<VideoControlItem> items = <VideoControlItem>[
      for (final VideoControlItem item in _layout.itemsIn(slot))
        if (_isOnVideoDraggableItem(item)) item,
    ];
    return DragTarget<VideoControlDragData>(
      key: ValueKey<String>('video-control-edit-slot-${slot.storageValue}'),
      onWillAcceptWithDetails:
          (DragTargetDetails<VideoControlDragData> details) {
        final VideoControlItem item = details.data.item;
        if (!_isOnVideoDraggableItem(item)) return false;
        return _canAcceptPayload(details.data, slot);
      },
      onAcceptWithDetails: (DragTargetDetails<VideoControlDragData> details) {
        _moveOrAddControlItem(details.data, slot, targetIndex: items.length);
      },
      builder: (
        BuildContext context,
        List<VideoControlDragData?> candidate,
        List<dynamic> rejected,
      ) {
        final bool highlighted = candidate.isNotEmpty;
        final bool rejecting = rejected.isNotEmpty;
        final Color borderColor = rejecting
            ? cs.error
            : highlighted
                ? cs.primary
                : restBorder;
        return AnimatedContainer(
          duration: colorSpring.duration,
          curve: colorSpring.curve,
          constraints: BoxConstraints(
            minHeight: tray ? 64 : 84,
            maxHeight: tray ? 120 : 176,
          ),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: highlighted ? cs.secondaryContainer : restColor,
            borderRadius: FushiM3eShape.cardRadius,
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
                style: labelStyle.copyWith(
                  color: highlighted
                      ? cs.onSecondaryContainer
                      : cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              if (items.isEmpty)
                Text(
                  t.video_control_slot_drop_hint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: hintStyle.copyWith(
                    color: highlighted
                        ? cs.onSecondaryContainer
                        : cs.onSurfaceVariant,
                  ),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (int index = 0; index < items.length; index++)
                          _buildPlacedControlChip(
                            items[index],
                            sourceSlot: slot,
                            sourceIndex: index,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDraggableControlChip(
    VideoControlItem item, {
    required VideoControlSlot? sourceSlot,
    required int? sourceIndex,
    double maxWidth = 156,
  }) {
    final Widget chip = _controlChipBody(
      item,
      dragging: false,
      maxWidth: maxWidth,
    );
    return Draggable<VideoControlDragData>(
      data: VideoControlDragData(
        item: item,
        sourceSlot: sourceSlot,
        sourceIndex: sourceIndex,
      ),
      feedback: Material(
        color: Colors.transparent,
        child: _controlChipBody(item, dragging: true, maxWidth: 220),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: chip),
      child: chip,
    );
  }

  Widget _buildPlacedControlChip(
    VideoControlItem item, {
    required VideoControlSlot sourceSlot,
    required int sourceIndex,
  }) {
    final ThemeData theme = _theme;
    final ColorScheme cs = theme.colorScheme;
    final FushiSpringSpec colorSpring = context.fushiMotion.effectsFast;
    return DragTarget<VideoControlDragData>(
      onWillAcceptWithDetails:
          (DragTargetDetails<VideoControlDragData> details) =>
              _canAcceptPayload(details.data, sourceSlot),
      onAcceptWithDetails: (DragTargetDetails<VideoControlDragData> details) {
        _moveOrAddControlItem(
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
        final bool highlighted = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: colorSpring.duration,
          curve: colorSpring.curve,
          constraints: const BoxConstraints(maxWidth: 204),
          padding: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: highlighted ? cs.primaryContainer : cs.secondaryContainer,
            borderRadius: FushiM3eShape.smallRadius,
            border: Border.all(
              color: highlighted ? cs.primary : Colors.transparent,
              width: highlighted ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _buildDraggableControlChip(
                item,
                sourceSlot: sourceSlot,
                sourceIndex: sourceIndex,
                maxWidth: 112,
              ),
              // TODO-554: hide the remove "x" when the item cannot be removed on
              // this surface (touch keeps the settings entry pinned), so the UI
              // never offers a tap that would be silently rejected.
              if (item.canRemoveFromPlayer(
                isTouchControls: widget.isTouchControls,
              ))
                Theme(
                  data: theme.copyWith(
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: FushiIconButtonControl(
                    tooltip: t.video_control_remove_from_slot,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    icon: FushiIcon(
                      FushiIcons.close,
                      size: 14,
                      color: cs.onSecondaryContainer,
                    ),
                    onPressed: () => _removeControlItem(item, sourceSlot),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  bool _isOnVideoDraggableItem(VideoControlItem item) => item.isChipRenderable;

  Widget _controlChipBody(
    VideoControlItem item, {
    required bool dragging,
    required double maxWidth,
  }) {
    final ColorScheme cs = _theme.colorScheme;
    final Widget body = DecoratedBox(
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: FushiM3eShape.smallRadius,
        boxShadow: dragging
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(
              videoControlItemIcon(
                item,
                bindings: widget.customActionBindings,
              ),
              size: 15,
              color: cs.onSecondaryContainer,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                videoControlItemLabel(
                  item,
                  context,
                  bindings: widget.customActionBindings,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: context.fushiType.labelMedium.copyWith(
                  color: cs.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: body,
    );
  }

  bool _canAcceptPayload(
    VideoControlDragData payload,
    VideoControlSlot target,
  ) {
    final VideoControlItem item = payload.item;
    if (!_isOnVideoDraggableItem(item)) return false;
    if (!item.canMoveToSlot(
      target,
      isTouchControls: widget.isTouchControls,
    )) {
      return false;
    }
    final List<VideoControlItem> targetItems = _layout.itemsIn(target);
    if (payload.sourceSlot == target) return true;
    return !targetItems.contains(item);
  }

  void _moveOrAddControlItem(
    VideoControlDragData payload,
    VideoControlSlot target, {
    int? targetIndex,
  }) {
    final VideoControlLayout next = _layout.moveDraggedItem(
      payload,
      target,
      targetIndex: targetIndex,
    );
    if (next == _layout) return;
    setState(() {
      _layout = next;
      _dirty = true;
    });
  }

  void _removeControlItem(VideoControlItem item, VideoControlSlot slot) {
    // TODO-554: on touch the settings button is the sole in-player entry to this
    // very editor, so removing it would soft-lock the user out. Reject it here
    // (the chip's remove "x" path) the same way the drag-to-hidden path is.
    if (!item.canRemoveFromPlayer(isTouchControls: widget.isTouchControls)) {
      return;
    }
    final VideoControlLayout next = _layout.removeItemFromSlot(item, slot);
    if (next == _layout) return;
    setState(() {
      _layout = next;
      _dirty = true;
    });
  }

  Future<void> _saveDraft() async {
    await widget.onLayoutChanged(_layout);
    if (!mounted) return;
    widget.onClose();
  }

  void _cancelDraft() {
    widget.onClose();
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
