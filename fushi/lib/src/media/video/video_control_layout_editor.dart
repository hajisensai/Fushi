import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/controls/control_layout_editor.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_control_item_presentation.dart';
import 'package:fushi/src/media/video/video_custom_action_bindings.dart';
import 'package:fushi/src/media/video/video_custom_action_picker.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/utils.dart';

/// 控制条 9 槽位拖拽编辑器（TODO-274/312 phase 2）。从旧
/// `VideoQuickSettingsSheet._buildControlDragEditor` 系列方法原样抽出为独立控件
/// （阶段 B：面板改 schema 投影，本编辑器以 `SettingsCustomItem` 入 schema、仅播放
/// 中可见）；「重置布局」行改由并列的 schema action 项承载，经 [layout] +
/// didUpdateWidget 同步回本编辑器。
///
/// 拖放状态机 / 调色板 / 隐藏托盘 / 驳回提示已抽成泛型 [ControlLayoutEditor]
/// （`src/controls/`），本控件只保留视频域知识：9 槽舞台几何、图标 / 标签 / 槽位名、
/// volume / 必需项的驳回文案，以及「快捷键 N」chip 的点击改绑入口。
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
  /// 自定义「快捷键」按钮绑定的本地镜像：本地先改、UI 立刻反映，同时把新值交给外部
  /// 落盘（外部回传经 didUpdateWidget 同步回来）。布局本身的镜像在泛型编辑器里。
  late VideoCustomActionBindings _customActionBindings =
      widget.customActionBindings;

  @override
  void didUpdateWidget(VideoControlLayoutEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.customActionBindings != widget.customActionBindings) {
      _customActionBindings = widget.customActionBindings;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Future<void> Function(VideoControlLayout layout)? onLayoutChanged =
        widget.onLayoutChanged;
    return ControlLayoutEditor<VideoControlSlot, VideoControlItem>(
      layout: widget.layout.core,
      onLayoutChanged: onLayoutChanged == null
          ? null
          : (ControlLayout<VideoControlSlot, VideoControlItem> next) =>
              unawaited(onLayoutChanged(VideoControlLayout.fromCore(next))),
      isTouchControls: widget.isTouchControls,
      paletteItems: VideoControlItem.customizableItems,
      paletteTitle: t.video_control_palette_title,
      stageBuilder: _buildControlStagePreview,
      iconOf: (VideoControlItem item) =>
          videoControlItemIcon(item, bindings: _customActionBindings),
      labelOf: (VideoControlItem item) => videoControlItemLabel(
        item,
        context,
        bindings: _customActionBindings,
      ),
      slotLabelOf: _controlSlotLabel,
      rejectionMessageOf: _controlRejectionMessage,
      dragCanceledMessageOf: _controlDragCanceledMessage,
      canRenderChip: (VideoControlItem item) => item.isChipRenderable,
      wrapChip: _wrapCustomActionChip,
      keyPrefix: 'video-control',
    );
  }

  Widget _buildControlStagePreview(
    BuildContext context,
    ControlSlotRegionBuilder<VideoControlSlot> buildSlotRegion,
  ) {
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
                  _buildCompactSlotGrid(buildSlotRegion, <VideoControlSlot>[
                    VideoControlSlot.topLeft,
                    VideoControlSlot.topCenter,
                    VideoControlSlot.topRight,
                  ]),
                  SizedBox(height: tokens.spacing.gap),
                  _buildCompactSlotGrid(buildSlotRegion, <VideoControlSlot>[
                    VideoControlSlot.screenLeft,
                    VideoControlSlot.screenRight,
                  ]),
                  SizedBox(height: tokens.spacing.gap),
                  _buildCompactSlotGrid(buildSlotRegion, <VideoControlSlot>[
                    VideoControlSlot.bottomLeft,
                    VideoControlSlot.bottomCenter,
                    VideoControlSlot.bottomRight,
                  ]),
                ],
              ),
            ),
          );
        }

        // BUG-2448：宽窗舞台不再是「固定高 Stack + 绝对定位」。那套布局里同一侧的
        // 顶栏 / 屏幕侧 / 底栏三个槽位各按内容长高，却没有任何约束阻止它们互相盖住，
        // 平板宽度（480~900）上右列直接挤成一团，chip 还被槽位内的嵌套滚动截断。
        // 现在按三行堆叠（顶栏行 / 屏幕侧行 / 底栏行），每行高度由内容决定、槽位
        // 完整展开；舞台只保留 16:9 的**最小**高度维持播放器方位感，内容更高时
        // 整体跟着长——外层设置页本来就是纵向滚动，长高不会截断任何东西。
        final double stageWidth = constraints.maxWidth;
        final double stageMinHeight = math.min(
          420,
          math.max(260, stageWidth * 9 / 16),
        );
        const double inset = 10;
        final double innerWidth = stageWidth - inset * 2;
        final double sideWidth =
            math.min(224, math.max(128, innerWidth * 0.24));
        final double centerWidth =
            math.min(236, math.max(128, innerWidth * 0.22));
        final double gap = tokens.spacing.gap;
        return DecoratedBox(
          key: const ValueKey<String>('video-control-editor-preview'),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: tokens.radii.controlRadius,
            border: Border.all(color: cs.outlineVariant),
          ),
          child: ClipRRect(
            borderRadius: tokens.radii.controlRadius,
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
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: stageMinHeight),
                child: Padding(
                  padding: const EdgeInsets.all(inset),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildStageRow(
                        buildSlotRegion,
                        left: VideoControlSlot.topLeft,
                        center: VideoControlSlot.topCenter,
                        right: VideoControlSlot.topRight,
                        sideWidth: sideWidth,
                        centerWidth: centerWidth,
                        crossAxisAlignment: CrossAxisAlignment.start,
                      ),
                      SizedBox(height: gap),
                      _buildStageRow(
                        buildSlotRegion,
                        left: VideoControlSlot.screenLeft,
                        center: null,
                        right: VideoControlSlot.screenRight,
                        sideWidth: sideWidth,
                        centerWidth: centerWidth,
                        crossAxisAlignment: CrossAxisAlignment.center,
                      ),
                      SizedBox(height: gap),
                      _buildStageRow(
                        buildSlotRegion,
                        left: VideoControlSlot.bottomLeft,
                        center: VideoControlSlot.bottomCenter,
                        right: VideoControlSlot.bottomRight,
                        sideWidth: sideWidth,
                        centerWidth: centerWidth,
                        crossAxisAlignment: CrossAxisAlignment.end,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 舞台一行：左右两个侧槽位定宽贴边、中央槽位居中；[center] 为 null 时中央留空
  /// （屏幕侧行没有中央槽位）。槽位按内容长高，行高取三者最高，互不重叠。
  Widget _buildStageRow(
    ControlSlotRegionBuilder<VideoControlSlot> buildSlotRegion, {
    required VideoControlSlot left,
    required VideoControlSlot? center,
    required VideoControlSlot right,
    required double sideWidth,
    required double centerWidth,
    required CrossAxisAlignment crossAxisAlignment,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: crossAxisAlignment,
      children: <Widget>[
        SizedBox(
          width: sideWidth,
          child: buildSlotRegion(left, growToContent: true),
        ),
        if (center != null)
          SizedBox(
            width: centerWidth,
            child: buildSlotRegion(center, growToContent: true),
          ),
        SizedBox(
          width: sideWidth,
          child: buildSlotRegion(right, growToContent: true),
        ),
      ],
    );
  }

  Widget _buildCompactSlotGrid(
    ControlSlotRegionBuilder<VideoControlSlot> buildSlotRegion,
    List<VideoControlSlot> slots,
  ) {
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
                child: buildSlotRegion(slot, growToContent: true),
              ),
          ],
        );
      },
    );
  }

  /// 「快捷键 N」槽位：点一下选它执行哪个动作（拖动仍然照常改位置——Draggable 用的是
  /// 即时拖拽识别器，与 onTap 在手势竞技场里按「有没有位移」自然分流，不互相吃事件）。
  /// 这是本功能唯一的配置入口：按钮就在编辑器里，点它配、拖它摆，不用去别的页面找。
  Widget _wrapCustomActionChip(
    BuildContext context,
    VideoControlItem item,
    Widget chip,
  ) {
    if (!item.isCustomAction || widget.onCustomActionBindingsChanged == null) {
      return chip;
    }
    return GestureDetector(
      onTap: () => unawaited(_pickCustomAction(item)),
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

  /// 拖到任何目标外松手：只有 volume 需要解释（它被限制在底栏，拖去别处会被所有
  /// 槽位拒收，松手时给一句为什么）。
  String? _controlDragCanceledMessage(VideoControlItem item) =>
      item == VideoControlItem.volume
          ? t.video_control_reject_volume_bottom
          : null;

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
